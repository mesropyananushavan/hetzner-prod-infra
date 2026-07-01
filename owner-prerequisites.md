# Что нужно подготовить перед реализацией Hetzner prod infra

Этот документ — список вещей, которые должен сделать или подтвердить владелец проекта до того, как мы
начнём применять Terraform/K3s/GitOps из `hetzner-prod-infra-plan.md`.

Главное правило: секреты не присылать в чат и не коммитить в git. Токены, пароли и приватные ключи храни в
password manager / 1Password / Vault / Bitwarden. В репозиторий попадают только примеры и зашифрованные
SealedSecret.

---

## 1. Hetzner

- [ ] Создать новый отдельный Hetzner Cloud Project, не старый project со smp-кластером.
- [ ] Включить billing/payment method, чтобы Terraform мог создавать ресурсы.
- [ ] Создать Hetzner Cloud API token с правами Read & Write.
- [ ] Сохранить `HCLOUD_TOKEN` в password manager.
- [ ] Проверить, что новый project пустой:
  ```bash
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers | jq .
  ```
  Ожидаемо: `{"servers": []}`.
- [ ] Создать Hetzner Object Storage bucket для Terraform state.
- [ ] Включить versioning на bucket.
- [ ] Подготовить Object Storage credentials для S3-compatible backend.
- [ ] Записать endpoint bucket, например `https://fsn1.your-objectstorage.com`.

Важно: серверы руками покупать не нужно. Их создаст Terraform. Руками нужен только Hetzner Project, API
token и Object Storage bucket для state.

---

## 2. Git

- [ ] Создать git repository для инфраструктуры, например `hetzner-prod-infra`.
- [ ] Решить, где он живёт: GitHub personal account или organization.
- [ ] Дать мне URL репозитория без секретов.
- [ ] Создать branch `main`.
- [ ] Подготовить GitHub token для Flux bootstrap с правами на этот repo.
- [ ] Подготовить отдельный fine-grained `GITOPS_TOKEN` для CI/CD приложений, с доступом только к infra repo.
- [ ] В GitHub Environments создать environment `production`.
- [ ] Включить Required reviewers для `production`, чтобы deploy в общий prod требовал ручного approve.

---

## 3. SSH и доступ

- [ ] Создать отдельный SSH key только для новой prod infra:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/hetzner_prod_v2 -C "hetzner-prod-v2-deploy"
  ```
- [ ] Не использовать старый личный `id_rsa`/`id_ed25519`.
- [ ] Сохранить приватный ключ локально и в backup/password manager.
- [ ] Подготовить публичный ключ `~/.ssh/hetzner_prod_v2.pub` для Terraform.
- [ ] Узнать текущий публичный IP:
  ```bash
  curl -s https://ifconfig.me
  ```
- [ ] Решить, будет ли SSH доступ только с текущего `/32`, через VPN/static IP, или временно шире.

---

## 4. Домены и DNS

- [ ] Подтвердить список production доменов:
  - [ ] smart-rest: `TODO`
  - [ ] fitness: `TODO`
  - [ ] beauty: `TODO`
  - [ ] mootq-v2: `TODO`
- [ ] Подтвердить, где управляется DNS: Cloudflare / registrar / другое.
- [ ] Убедиться, что есть доступ менять A/AAAA/CNAME records.
- [ ] Перед go-live снизить DNS TTL для доменов, которые будут переключаться.
- [ ] Подготовить один тестовый поддомен для проверки cert-manager/Traefik, например `test-prod.example.com`.

---

## 5. Container registry

- [ ] Выбрать registry:
  - [ ] GitHub Container Registry
  - [ ] Docker Hub private
  - [ ] self-hosted registry
  - [ ] другое: `TODO`
- [ ] Подготовить registry credentials для CI/CD.
- [ ] Подтвердить image names, например:
  - `registry.example.com/smart-rest`
  - `registry.example.com/fitness`
  - `registry.example.com/beauty`
  - `registry.example.com/mootq-v2`
- [ ] Убедиться, что Kubernetes сможет pull private images. Для этого позже понадобится `imagePullSecret`.

---

## 6. Приложения

Для каждого проекта подготовить:

- [ ] Git repo URL приложения.
- [ ] Dockerfile или подтверждение, что image уже собирается.
- [ ] Команда тестов для CI:
  - smart-rest: `TODO`
  - fitness: `TODO`
  - beauty: `TODO`
  - mootq-v2: `TODO`
- [ ] Health endpoint, например `/health`.
- [ ] Нужные env vars.
- [ ] Список секретов: DB password, API keys, SMTP, S3 keys, etc.
- [ ] Нужные cron jobs.
- [ ] Нужные queue workers.
- [ ] Нужные migration commands.
- [ ] Нужные persistent files: что уходит в Object Storage, что нельзя хранить в pod filesystem.

Не присылай значения секретов в чат. Достаточно списка имён секретов и где они будут храниться.

---

## 7. Базы данных и Redis

- [ ] Подтвердить, что на старте MariaDB будет отдельной VM без HA, но с backup/restore test.
- [ ] Подтвердить, какие базы нужны:
  - [ ] `smartrest`
  - [ ] `fitness`
  - [ ] `beauty`
  - [ ] `mootq`
- [ ] Подтвердить, нужен ли Redis.
- [ ] Если Redis нужен, выбрать:
  - [ ] отдельная VM
  - [ ] внутри Kubernetes, если downtime допустим
- [ ] Подготовить требования по retention/backup для DB.
- [ ] Подготовить примерный размер текущих DB, если есть старый прод.

---

## 8. Monitoring и alerts

- [ ] Выбрать канал алертов:
  - [ ] Telegram
  - [ ] Slack
  - [ ] Email
  - [ ] другое: `TODO`
- [ ] Подготовить bot token/webhook для Alertmanager.
- [ ] Определить людей, кто реально получает prod alerts.
- [ ] Подтвердить, что Grafana не будет публичной без VPN/basic-auth/oauth2-proxy.

---

## 9. Локальная машина для запуска

- [ ] Машина, с которой запускаем bootstrap, имеет Linux/macOS или WSL.
- [ ] Установлены:
  - [ ] Terraform
  - [ ] kubectl
  - [ ] helm
  - [ ] flux CLI
  - [ ] hcloud CLI
  - [ ] jq
  - [ ] kubeseal
- [ ] Есть доступ к git repo.
- [ ] Есть доступ к Hetzner token и Object Storage credentials.
- [ ] Есть SSH key `~/.ssh/hetzner_prod_v2`.

---

## 10. Решения, которые надо подтвердить до старта

- [ ] Hetzner location: `fsn1` или другое.
- [ ] Размеры VM на старте:
  - control-plane: `cpx31 x 3`
  - workers: `cpx41 x 4`
  - db: `cpx41 x 1`
- [ ] Бюджет примерно `170-200 EUR/month` плюс storage/traffic.
- [ ] Стартуем с одним кластером на все проекты через namespaces.
- [ ] Старый smp-кластер не трогаем.
- [ ] Go-live не делаем поздно вечером/в пятницу.
- [ ] Перед реальным DNS switch делаем тест через `curl --resolve`.

---

## Что можно начинать после этого

Когда пункты выше закрыты, можно переходить к реализации:

1. Создать структуру repo.
2. Написать Terraform backend/provider/network/firewalls/servers/LB.
3. Подготовить cloud-init K3s templates.
4. Сделать `terraform init/validate/plan`.
5. Запустить тестовый apply в новом Hetzner Project.
6. Пройти проверки из `hetzner-prod-infra-plan.md`.
