data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "test" {
  count                  = var.instance_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = var.key_name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    name = "lab00-${count.index + 1}"
    port = var.test_port
  })

  tags = { Name = "lab00-${count.index + 1}" }
}

# Lets you type `ssh lab00-1` instead of an IP. Overwrites ~/.ssh/config (fresh workspace).
resource "local_file" "ssh_config" {
  filename        = pathexpand("~/.ssh/config")
  file_permission = "0600"
  content = join("", [for i, inst in aws_instance.test :
    "Host lab00-${i + 1}\n  HostName ${inst.public_ip}\n  User ubuntu\n  IdentityFile ${pathexpand("~/.ssh/${var.key_name}.id_rsa")}\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n\n"
  ])
}
