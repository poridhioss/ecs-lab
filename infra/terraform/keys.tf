# The SSH key is created by Terraform, so `terraform destroy` also deletes it.
# The private key is written to ~/.ssh on the workspace only.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  key_name   = "ecs-lab-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  filename        = pathexpand("~/.ssh/ecs-lab-key.id_rsa")
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0400"
}

# Shared secret the agents send to the control plane. New every session.
resource "random_password" "agent_token" {
  length  = 32
  special = false
}
