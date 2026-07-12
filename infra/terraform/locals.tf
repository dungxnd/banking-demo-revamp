locals {
  name_prefix = "banking-demo-${var.environment}"

  # Ports exposed by the k3s + Helm stack on the EC2 node:
  #   80   — Kong proxy (hostPort bound directly on the node NIC)
  #   6443 — k3s API server (kubectl / Helm access from your workstation)
  app_ports = [
    80,   # Kong proxy (hostPort)
    6443, # k3s API server
  ]
}
