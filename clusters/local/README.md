# Local verification

Local cluster is for testing Kubernetes manifests before using real Hetzner data.

It intentionally avoids:

- Hetzner Cloud API credentials
- Object Storage credentials
- production DNS
- production registry credentials
- real application secrets

## Preferred local runtime

Use `k3d` because it runs K3s locally and keeps the local behavior close to the
production K3s setup.

```bash
k3d cluster create --config clusters/local/k3d/cluster.yaml
kubectl config use-context k3d-hetzner-prod-local
kubectl kustomize clusters/local
kubectl apply -k clusters/local
kubectl -n kube-system rollout status daemonset/traefik
kubectl -n smoke-local rollout status deployment/smoke-web
curl -H 'Host: smoke.localhost' http://127.0.0.1:8080/
```

Delete the local cluster:

```bash
k3d cluster delete hetzner-prod-local
```

## Static check only

This does not require a running cluster:

```bash
kubectl kustomize clusters/local
```
