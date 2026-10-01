resource "aws_security_group" "cluster" {
  name   = "ecs-lab-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "SSH from the workspace (it has no fixed IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # One rule per browser-facing port in var.public_ports
  dynamic "ingress" {
    for_each = var.public_ports
    content {
      description = "Browser access"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Everything between cluster machines: agent <-> control plane, Temporal,
  # and later VXLAN (UDP 4789), Fluent Bit, Prometheus scrapes...
  ingress {
    description = "All traffic between machines in this group"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecs-lab-sg" }
}
