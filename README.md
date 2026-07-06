# Hetzner Prod Infra

Новый независимый Hetzner production cluster: Terraform + K3s HA + GitOps.

Главный план: `hetzner-prod-infra-plan.md`.
Список входных данных от владельца: `owner-prerequisites.md` и `owner-inputs.example.env`.
Рабочее состояние между сессиями: `PROJECT_STATE.md`.

## Что уже можно делать локально

```bash
cd infra/terraform/envs/prod
terraform init
terraform validate
terraform plan -out=tfplan
```

Перед запуском заменить placeholder в `backend.tf` на реальный Hetzner Object Storage endpoint, а реальные
значения держать в локальном `terraform.tfvars` или env vars. `terraform.tfvars` игнорируется git.

## Локальная проверка перед Hetzner

Для проверки Kubernetes/GitOps-слоя без реальных Hetzner данных добавлен local overlay:

```bash
kubectl kustomize clusters/local
bash scripts/local-validate.sh
```

Для полноценного локального smoke test нужен `k3d`:

```bash
k3d cluster create --config clusters/local/k3d/cluster.yaml
kubectl apply -k clusters/local
kubectl -n kube-system rollout status daemonset/traefik
kubectl -n smoke-local rollout status deployment/smoke-web
curl -H 'Host: smoke.localhost' http://127.0.0.1:8080/
curl -H 'Host: smart-rest.localhost' http://127.0.0.1:8080/
```

## Нюанс первого применения prod-манифестов

Первый `kubectl apply -k clusters/prod` упадёт на ClusterIssuer'ах ("no matches for kind ClusterIssuer") —
CRD появляются только после того, как helm-controller установит cert-manager. Это ожидаемо: дождись
`kubectl -n kube-system wait --for=condition=complete job/helm-install-cert-manager` и повтори apply.

## Важные ограничения

- Старый `smp` кластер не трогаем.
- Реальные токены, пароли, private keys, kubeconfig и Terraform state не коммитим.
- Перед боевым apply нужно проверить имя приватного интерфейса на тестовой Hetzner VM.
- CLI установлены в `~/.local/bin`.
- `terraform init -backend=false` и `terraform validate` уже прошли успешно.
- `terraform plan/apply` пока не запускались, потому что нужны реальные Hetzner/Object Storage данные.
