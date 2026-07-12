output "instance_id" {
  description = "EC2 instance ID"
  type        = string
  value       = aws_instance.main.id
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  type        = string
  value       = aws_instance.main.public_ip
}

output "public_dns" {
  description = "Public DNS hostname of the EC2 instance"
  type        = string
  value       = aws_instance.main.public_dns
}

output "ssh_command" {
  description = "Ready-to-use SSH command to connect to the instance"
  type        = string
  value       = "ssh -i ${pathexpand(var.private_key_path)} ubuntu@${aws_instance.main.public_ip}"
}

output "ansible_inventory_path" {
  description = "Path of the generated Ansible inventory file"
  type        = string
  value       = pathexpand(var.ansible_inventory_path)
}

output "key_pair_name" {
  description = "Name of the AWS key pair"
  type        = string
  value       = data.aws_key_pair.main.key_name
}
