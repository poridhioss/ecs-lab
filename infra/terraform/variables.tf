variable "region" {
  default = "ap-southeast-1"
}

variable "az" {
  default = "ap-southeast-1a"
}

# Every machine in the cluster and its FIXED private IP.
# Fixed IPs mean every config file can name its peers up front
# (the agent knows where the control plane is before either machine exists).
# Later labs add obs-01 (10.0.1.30) and auth-01 (10.0.1.40) here.
variable "machines" {
  default = {
    "control-01" = "10.0.1.10"
    "node-01"    = "10.0.1.21"
    "node-02"    = "10.0.1.22"
  }
}

# Ports opened to the internet, for browsers: control plane API, Temporal UI.
variable "public_ports" {
  default = [8000, 8233]
}
