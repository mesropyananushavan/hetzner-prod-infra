terraform {
  required_version = ">= 1.5"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

locals {
  # Приватные IP control-plane нод; из этого же списка собираются --tls-san,
  # чтобы сертификат API покрывал все CP при любом control_plane_count.
  cp_private_ips = [for i in range(var.control_plane_count) : "10.10.1.${10 + i}"]
  tls_san_args   = join(" ", [for ip in local.cp_private_ips : "--tls-san=${ip}"])
}

resource "hcloud_network" "main" {
  name     = "hetzner-prod-net"
  ip_range = "10.10.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.10.1.0/24"
}

resource "hcloud_firewall" "control_plane" {
  name = "control-plane-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.allowed_ssh_ip]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_firewall" "workers" {
  name = "workers-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.allowed_ssh_ip]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_ssh_key" "default" {
  name       = "hetzner-prod-v2-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "hcloud_placement_group" "control_plane" {
  name = "cp-spread"
  type = "spread"
}

resource "hcloud_server" "control_plane" {
  count              = var.control_plane_count
  name               = "cp-${count.index + 1}"
  server_type        = "cpx31"
  image              = "ubuntu-24.04"
  location           = "fsn1"
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.control_plane.id]
  placement_group_id = hcloud_placement_group.control_plane.id

  network {
    network_id = hcloud_network.main.id
    ip         = "10.10.1.${10 + count.index}"
  }

  user_data = count.index == 0 ? templatefile("${path.module}/../../cloud-init/control-plane.yaml.tpl", {
    k3s_token    = var.k3s_token
    k3s_version  = var.k3s_version
    private_ip   = local.cp_private_ips[count.index]
    tls_san_args = local.tls_san_args
    }) : templatefile("${path.module}/../../cloud-init/control-plane-join.yaml.tpl", {
    k3s_token    = var.k3s_token
    k3s_version  = var.k3s_version
    first_cp_ip  = local.cp_private_ips[0]
    private_ip   = local.cp_private_ips[count.index]
    tls_san_args = local.tls_san_args
  })

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_placement_group" "workers" {
  name = "worker-spread"
  type = "spread"
}

resource "hcloud_server" "worker" {
  count              = var.worker_count
  name               = "worker-${count.index + 1}"
  server_type        = "cpx41"
  image              = "ubuntu-24.04"
  location           = "fsn1"
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.workers.id]
  placement_group_id = hcloud_placement_group.workers.id

  network {
    network_id = hcloud_network.main.id
    ip         = "10.10.1.${50 + count.index}"
  }

  user_data = templatefile("${path.module}/../../cloud-init/worker.yaml.tpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    cp_ip       = "10.10.1.10"
    private_ip  = "10.10.1.${50 + count.index}"
  })

  depends_on = [hcloud_server.control_plane]
}

resource "hcloud_load_balancer" "main" {
  name               = "hetzner-prod-lb"
  load_balancer_type = "lb11"
  location           = "fsn1"
}

resource "hcloud_load_balancer_network" "main" {
  load_balancer_id = hcloud_load_balancer.main.id
  network_id       = hcloud_network.main.id
}

resource "hcloud_load_balancer_target" "workers" {
  count            = var.worker_count
  type             = "server"
  load_balancer_id = hcloud_load_balancer.main.id
  server_id        = hcloud_server.worker[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.main]
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443

  # Явный health check: во время rollout Traefik (maxUnavailable: 2) LB должен
  # быстро выкидывать ноды, где ingress не слушает, иначе клиенты ловят ошибки.
  health_check {
    protocol = "tcp"
    port     = 443
    interval = 5
    timeout  = 3
    retries  = 2
  }
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 5
    timeout  = 3
    retries  = 2
  }
}
