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

## Важные ограничения

- Старый `smp` кластер не трогаем.
- Реальные токены, пароли, private keys, kubeconfig и Terraform state не коммитим.
- Перед боевым apply нужно проверить имя приватного интерфейса на тестовой Hetzner VM.
- CLI установлены в `~/.local/bin`.
- `terraform init -backend=false` и `terraform validate` уже прошли успешно.
- `terraform plan/apply` пока не запускались, потому что нужны реальные Hetzner/Object Storage данные.
