[banking_demo]
${public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${ssh_key_dest} ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[banking_demo:vars]
ansible_python_interpreter=/usr/bin/python3
