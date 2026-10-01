output "public_ips" {
  value = { for name, inst in aws_instance.machine : name => inst.public_ip }
}

output "control_public_ip" {
  value = aws_instance.machine["control-01"].public_ip
}

output "urls" {
  value = {
    control_plane = "http://${aws_instance.machine["control-01"].public_ip}:8000/agents"
    temporal_ui   = "http://${aws_instance.machine["control-01"].public_ip}:8233/"
  }
}

output "agent_token" {
  value     = random_password.agent_token.result
  sensitive = true
}
