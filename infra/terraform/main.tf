# ── Key Pair ─────────────────────────────────────────────────────────────────
# Look up an existing AWS key pair by name — Terraform does not create or
# modify it. Set key_name in terraform.tfvars to the name shown in the
# AWS console (EC2 → Key Pairs).

data "aws_key_pair" "main" {
  key_name = var.key_name
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = { Name = "${local.name_prefix}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# v6 best practice: use standalone ingress/egress rule resources (one CIDR per
# rule) instead of inline ingress/egress blocks on aws_security_group.

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-sg"
  description = "Allow SSH and banking-demo application traffic"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-sg" }
}

# SSH — one rule per CIDR block
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.instance.id
  description       = "SSH"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  tags = { Name = "${local.name_prefix}-ssh-${each.key}" }
}

# Application ports (Caddy HTTP 80, Caddy HTTPS 443) —
# one rule per port × CIDR combination.
resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = {
    for pair in setproduct(local.app_ports, var.allowed_app_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.instance.id
  description       = "App port ${each.value.port}"
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = { Name = "${local.name_prefix}-app-${each.key}" }
}

# All outbound (package installs, container image pulls, k3s, etc.)
resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.instance.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = { Name = "${local.name_prefix}-egress-all" }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

# Use the caller-supplied AMI if provided, otherwise resolve the latest Ubuntu 26.04 LTS.
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
}

resource "aws_instance" "main" {
  ami                    = local.resolved_ami
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.main.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # cloud-init: minimal bootstrap so Ansible can SSH in and run immediately.
  # k3s, Helm, and all app dependencies are installed by the Ansible k3s role.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl git python3
  EOF

  tags = { Name = "${local.name_prefix}-server" }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# ── Ansible Inventory ─────────────────────────────────────────────────────────

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tpl", {
    public_ip    = aws_instance.main.public_ip
    # Always write the key destination as ~/.ssh/<filename> so the generated
    # hosts.ini works on both WSL and native Linux — deploy.sh copies the key
    # from var.private_key_path to this canonical location before running Ansible.
    ssh_key_dest = "~/.ssh/${basename(var.private_key_path)}"
  })
  filename        = pathexpand(var.ansible_inventory_path)
  file_permission = "0644"
}

resource "local_file" "ansible_group_vars" {
  content = templatefile("${path.module}/group_vars.tpl", {
    public_ip  = aws_instance.main.public_ip
    aws_region = var.aws_region
  })
  filename        = pathexpand(var.ansible_group_vars_path)
  file_permission = "0644"
}
