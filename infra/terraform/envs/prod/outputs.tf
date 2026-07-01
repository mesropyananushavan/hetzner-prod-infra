output "lb_public_ip" {
  value = hcloud_load_balancer.main.ipv4
}

output "control_plane_ips" {
  value = hcloud_server.control_plane[*].ipv4_address
}

output "worker_ips" {
  value = hcloud_server.worker[*].ipv4_address
}
