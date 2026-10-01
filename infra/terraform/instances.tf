data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "machine" {
  for_each = var.machines

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public.id
  private_ip             = each.value
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.lab.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    name        = each.key
    control_ip  = var.machines["control-01"]
    agent_token = random_password.agent_token.result
  })

  tags = { Name = each.key }
}

# Lets the workspace type `ssh control-01` instead of an IP.
resource "local_file" "ssh_config" {
  filename        = pathexpand("~/.ssh/config")
  file_permission = "0600"
  content = join("", [for name, inst in aws_instance.machine :
    "Host ${name}\n  HostName ${inst.public_ip}\n  User ubuntu\n  IdentityFile ${local_sensitive_file.ssh_key.filename}\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n\n"
  ])
}
