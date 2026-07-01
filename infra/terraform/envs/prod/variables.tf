variable "hcloud_token" {
  sensitive   = true
  description = "Hetzner Cloud API token for the new empty production project."
}

variable "k3s_token" {
  sensitive   = true
  description = "Shared K3s cluster token. Generate with: openssl rand -hex 32"
}

variable "k3s_version" {
  default     = "v1.35.6+k3s1"
  description = "Check k3s and Kubernetes patch release support immediately before terraform apply."
}

variable "control_plane_count" {
  default     = 3
  description = "Must be an odd number for etcd quorum."

  validation {
    condition     = var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be odd."
  }
}

variable "worker_count" {
  default = 4
}

variable "ssh_public_key_path" {
  default = "~/.ssh/hetzner_prod_v2.pub"
}

variable "allowed_ssh_ip" {
  description = "Your public SSH source IP in CIDR form, for example 203.0.113.5/32."
}
