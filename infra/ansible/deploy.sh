#!/usr/bin/env bash
# deploy.sh â€” run ansible-playbook from WSL or native Linux without manual setup.
#
# Solves three WSL friction points automatically:
#   1. Copies the SSH key from /mnt/c/... to ~/.ssh/ and sets chmod 600
#   2. Copies ansible.cfg to ~/ so it isn't ignored (world-writable /mnt/c warning)
#   3. Sets ANSIBLE_CONFIG so Ansible picks up the safe copy
#
# Usage:
#   ./deploy.sh                          # full provisioning (site.yml)
#   ./deploy.sh --tags app               # re-deploy Helm release only
#   ./deploy.sh --check --diff           # dry run
#   ./deploy.sh -p install-instana.yml \ # install Instana agent (secrets via -e)
#     -e agent_key=<KEY> \
#     -e agent_download_key=<DL_KEY> \
#     -e endpoint_host=<host>
#
# -p <playbook>  Run a specific playbook instead of site.yml (default).
# Any other arguments are forwarded to ansible-playbook as-is.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_INI="$SCRIPT_DIR/inventories/vps/hosts.ini"
ANSIBLE_CFG_DEST="$HOME/ansible-banking.cfg"

# â”€â”€ 1. Sanity checks â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

if [ ! -f "$HOSTS_INI" ]; then
  echo "ERROR: $HOSTS_INI not found."
  echo "  Run 'terraform apply' first (from infra/terraform/) to generate it."
  exit 1
fi

# Detect placeholder inventory (no real host line â€” Terraform hasn't run yet)
if ! grep -qP '^\d+\.\d+\.\d+\.\d+' "$HOSTS_INI"; then
  echo "ERROR: $HOSTS_INI contains no host â€” Terraform has not been applied yet."
  echo ""
  echo "  On Windows PowerShell:"
  echo "    cd infra/terraform"
  echo "    terraform apply"
  echo ""
  echo "  Then re-run: ./deploy.sh"
  exit 1
fi

# â”€â”€ 2. Resolve the SSH key path from hosts.ini â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# The key is written as ~/.ssh/<name> by Terraform (inventory.tpl).
# Expand ~ manually so we can locate the source file for copying.

# grep -oP exits 1 if no match; use || true so pipefail doesn't kill the script
RAW_KEY=$(grep -oP 'ansible_ssh_private_key_file=\K\S+' "$HOSTS_INI" | head -1 || true)
if [ -z "$RAW_KEY" ]; then
  echo "ERROR: could not parse ansible_ssh_private_key_file from $HOSTS_INI"
  exit 1
fi

# Expand leading ~ to $HOME
SSH_KEY_DEST="${RAW_KEY/#\~/$HOME}"
KEY_FILENAME="$(basename "$SSH_KEY_DEST")"

# â”€â”€ 3. Find the source key (handles WSL Windows path or already in ~/.ssh) â”€â”€â”€

find_source_key() {
  # Already exists at destination â€” nothing to copy
  if [ -f "$SSH_KEY_DEST" ]; then
    echo "$SSH_KEY_DEST"
    return
  fi

  # Look for the key under /mnt/c (WSL Windows home)
  local win_home
  win_home=$(wslpath "C:/Users" 2>/dev/null || echo "/mnt/c/Users")
  local candidate
  for user_dir in "$win_home"/*/; do
    candidate="$user_dir/.ssh/$KEY_FILENAME"
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done

  echo ""
}

KEY_SRC=$(find_source_key)

if [ -z "$KEY_SRC" ]; then
  echo "ERROR: SSH key '$KEY_FILENAME' not found in ~/.ssh/ or any Windows user profile."
  echo "  Place the key at ~/.ssh/$KEY_FILENAME and re-run."
  exit 1
fi

# â”€â”€ 4. Copy key to WSL-native ~/.ssh/ (no-op if already there) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

if [ "$KEY_SRC" != "$SSH_KEY_DEST" ]; then
  mkdir -p "$HOME/.ssh"
  echo "Copying SSH key: $KEY_SRC â†’ $SSH_KEY_DEST"
  cp "$KEY_SRC" "$SSH_KEY_DEST"
fi

chmod 600 "$SSH_KEY_DEST"

# â”€â”€ 5. Generate ansible.cfg at ~/ansible-banking.cfg â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# ansible.cfg uses relative paths (good for portability) but when Ansible loads
# a cfg it resolves relative paths from the cfg's own directory. Writing it to
# ~/ would break inventory= and roles_path=. Instead we generate a cfg with the
# correct absolute paths derived from $SCRIPT_DIR at runtime â€” no hardcoded paths
# in the committed file, no world-writable /mnt/c warning.

echo "Generating $ANSIBLE_CFG_DEST"
cat > "$ANSIBLE_CFG_DEST" <<EOF
[defaults]
inventory          = $SCRIPT_DIR/inventories/vps/hosts.ini
roles_path         = $SCRIPT_DIR/roles
remote_user        = ubuntu
private_key_file   = $SSH_KEY_DEST

pipelining         = True
forks              = 5
gathering          = smart
fact_caching            = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout    = 86400

stdout_callback       = ansible.builtin.default
result_format         = yaml
display_skipped_hosts = False
deprecation_warnings  = False

[ssh_connection]
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
pipelining = True
EOF

# â”€â”€ 6. Parse -p <playbook> from args, forward everything else â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

PLAYBOOK="site.yml"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--playbook)
      PLAYBOOK="$2"
      shift 2
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

# â”€â”€ 7. Run ansible-playbook â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

export ANSIBLE_CONFIG="$ANSIBLE_CFG_DEST"

echo ""
echo "Running: ansible-playbook $PLAYBOOK ${EXTRA_ARGS[*]+"${EXTRA_ARGS[@]}"}"
echo "  Config : $ANSIBLE_CONFIG"
echo "  Key    : $SSH_KEY_DEST"
echo ""

cd "$SCRIPT_DIR"
exec ansible-playbook "$PLAYBOOK" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
