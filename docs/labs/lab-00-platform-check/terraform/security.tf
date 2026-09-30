resource "aws_security_group" "lab" {
  name   = "lab00-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "SSH from the workspace (no fixed IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Browser test port"
    from_port   = var.test_port
    to_port     = var.test_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "All traffic between instances in this group"
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

  tags = { Name = "lab00-sg" }
}
