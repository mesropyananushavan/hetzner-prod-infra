#cloud-config
package_update: true

runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${k3s_token} sh -s - server \
      --server https://${first_cp_ip}:6443 \
      --disable servicelb \
      --disable-cloud-controller \
      --kubelet-arg=cloud-provider=external \
      --kubelet-arg=container-log-max-size=50Mi \
      --kubelet-arg=container-log-max-files=3 \
      --node-ip=${private_ip} \
      --advertise-address=${private_ip} \
      --flannel-iface=enp7s0 \
      --tls-san=10.10.1.10 \
      --tls-san=10.10.1.11 \
      --tls-san=10.10.1.12 \
      --node-taint=node-role.kubernetes.io/control-plane:NoSchedule
  - ufw allow from 10.10.0.0/16
  - ufw allow 22/tcp
  - ufw --force enable
