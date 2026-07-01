# Hetzner Prod Infra - рабочее состояние

Этот файл нужен, чтобы не терять контекст между сессиями. Обновлять его после значимых изменений.

## Текущий статус

- Репозиторий инициализирован локально, ветка: `main`.
- Старый `smp` кластер не трогаем.
- Работа идёт только внутри `/home/am/work/projects/hetzner-prod-infra`.
- Реальные секреты, токены, private keys, kubeconfig и Terraform state в git не кладём.

## Сделано

- Прочитан `hetzner-prod-infra-plan.md`.
- Найден существующий `owner-prerequisites.md`.
- Создан базовый scaffold каталогов для Terraform, cloud-init и GitOps manifests.
- Добавлен `.gitignore`.
- Добавлен шаблон входных данных `owner-inputs.example.env`.
- Добавлен начальный Terraform scaffold: network, firewalls, servers, LB, outputs, tfvars example.
- Добавлены cloud-init шаблоны K3s для cp-1, cp-2/cp-3 и workers.
- Добавлены стартовые manifests для Traefik, cert-manager ClusterIssuer и NetworkPolicy template.
- User-local установлены CLI в `~/.local/bin`: Terraform v1.15.7, kubectl v1.36.2, Helm v3.21.2, Flux
  v2.9.0, hcloud v1.66.0, jq 1.8.2, kubeseal v0.38.1.
- Выполнены `terraform fmt -recursive`, `terraform init -backend=false`, `terraform validate`.

## Следующий безопасный шаг

1. Владелец заполняет реальные значения локально в `owner-inputs.local.env` или в password manager.
2. Создать Hetzner Object Storage bucket и уточнить S3 endpoint для `backend.tf`.
3. Создать локальный `infra/terraform/envs/prod/terraform.tfvars` с реальными значениями.
4. После этого запускать `terraform init` с remote backend в `infra/terraform/envs/prod`.

## Блокеры перед реальным apply

- Нет подтверждённого `HCLOUD_TOKEN` нового пустого Hetzner Project.
- Нет подтверждённых Object Storage S3 credentials/backend endpoint.
- Нужно проверить имя приватного интерфейса на тестовой VM перед боевым apply.
