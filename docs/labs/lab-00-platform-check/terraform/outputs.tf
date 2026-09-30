output "ami_id" {
  value = data.aws_ami.ubuntu.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "public_ips" {
  value = join(" ", aws_instance.test[*].public_ip)
}

output "private_ips" {
  value = join(" ", aws_instance.test[*].private_ip)
}

output "test_urls" {
  value = [for ip in aws_instance.test[*].public_ip : "http://${ip}:${var.test_port}/"]
}
