locals {
  name_prefix = "banking-demo-${var.environment}"

  # Ports exposed by the k3s + Helm stack on the EC2 node:
  #   80  — Caddy HTTP (hostNetwork, sole entry point)
  #   443 — Caddy HTTPS (TLS termination via Let's Encrypt)
  app_ports = [
    80,
    443,
  ]
}
