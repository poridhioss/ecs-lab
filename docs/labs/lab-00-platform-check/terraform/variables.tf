variable "region" {
  default = "ap-southeast-1"
}

variable "az" {
  default = "ap-southeast-1a"
}

# 5 = the capstone layout (control, obs, auth, node-01, node-02).
# If apply fails on the 4th or 5th instance, that is the instance cap.
variable "instance_count" {
  default = 5
}

variable "instance_type" {
  default = "t3.medium"
}

# Larger than the 8 GB default: Temporal, Elasticsearch and Authentik images need room.
# If apply fails with a volume-related UnauthorizedOperation, retry with -var root_volume_gb=8.
variable "root_volume_gb" {
  default = 20
}

variable "key_name" {
  default = "lab00-key"
}

# Browser-reachability test port (the control plane's port in the course).
variable "test_port" {
  default = 8000
}
