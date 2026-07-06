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
- Добавлен local-first слой `clusters/local` для проверки Kubernetes manifests без Hetzner secrets/data.
- Добавлены Kustomize entrypoints для `clusters/prod` и существующих prod infrastructure manifests.
- Добавлен `scripts/local-validate.sh` для статического рендера local/prod Kustomize.
- Установлен `k3d` v5.8.3 в `~/.local/bin`.
- Создан локальный k3d cluster `hetzner-prod-local`; `kubectl apply -k clusters/local` и HTTP smoke test через
  Traefik на `127.0.0.1:8080` прошли успешно.
- Локальная проверка выявила и исправила Traefik DaemonSet strategy: при `hostNetwork` нужен
  `maxUnavailable: 2` и `maxSurge: 0`.
- Локальная проверка выявила и исправила NetworkPolicy для hostNetwork Traefik: нужен ingress allow не только
  по pod selector, но и по K3s pod CIDR `10.42.0.0/16` / private node CIDR.
- Добавлен production skeleton только для `smart-rest`: namespace, quota, limitrange, deployment, service,
  ingress, PDB, HPA, NetworkPolicy.
- Добавлен local overlay только для `smart-rest`: placeholder image `traefik/whoami:v1.10`, host
  `smart-rest.localhost`, без TLS/secrets.
- `smart-rest` проверен локально в k3d: rollout успешный, HTTP через Traefik на
  `http://127.0.0.1:8080/` с Host `smart-rest.localhost` успешный.
- User-local установлены CLI в `~/.local/bin`: Terraform v1.15.7, kubectl v1.36.2, Helm v3.21.2, Flux
  v2.9.0, hcloud v1.66.0, jq 1.8.2, kubeseal v0.38.1.
- Выполнены `terraform fmt -recursive`, `terraform init -backend=false`, `terraform validate`.

## Четвёртый раунд ревью (2026-07-06) — исправленные блокеры

- **Worker-метка**: `node-role.kubernetes.io/worker=true` в `worker.yaml.tpl` не давала агенту
  зарегистрироваться (kubelet запрещает самоназначение меток в `kubernetes.io`; воспроизведено в k3d —
  агент висит в таймауте регистрации). Заменена на `node-role.smp.am/worker=true` в cloud-init,
  prod/local Traefik `nodeSelector` и k3d cluster.yaml; проверено в k3d: Traefik DaemonSet встаёт только
  на agent-нодах.
- **NetworkPolicy smart-rest**: политики были написаны под одноконтейнерное приложение — nginx не имел
  ingress/egress до php-fpm:9000, php-fpm не имел egress вообще (в т.ч. до MariaDB), правило 3306 висело
  на nginx. Переписано: `allow-nginx-to-php-fpm`, `allow-nginx-egress`, `allow-php-fpm-egress` (3306 →
  10.10.1.100, 443 наружу). Проверено в k3d: под с метками nginx достукивается до php-fpm, под без
  меток блокируется.
- **cert-manager не устанавливался**: были только ClusterIssuer'ы. Добавлен HelmChart CR (k3s
  helm-controller), версия закреплена `v1.20.3`. Email заменён с `devops@example.com` (LE отклоняет
  example.com) на `anushavan.m@smp.am`. Проверено на локальном кластере: оба issuer'а Ready, ACME
  аккаунты зарегистрированы. Первый `kubectl apply -k` падает на ClusterIssuer до готовности CRD —
  это ожидаемо, повторный apply после установки cert-manager проходит.
- **network-policies/app-template.yaml** больше не применяется kustomization'ом (namespace
  `example-prod` не существует — реальный apply падал бы); оставлен как copy-paste шаблон.
- **HPA vs `replicas`**: поле `replicas` убрано из обоих деплойментов (иначе каждый apply сбрасывал бы
  масштаб, воюя с HPA).
- **php-fpm без HPA/PDB**: добавлены `hpa-php-fpm.yaml` и `pdb-php-fpm.yaml` (для PHP-приложения именно
  fpm — узкое место).
- **Hetzner LB**: добавлены явные `health_check` (tcp, interval 5s) на 80/443 — при rollout Traefik с
  `maxUnavailable: 2` LB должен быстро выкидывать ноды без живого ingress.
- **`--tls-san`** больше не захардкожен на 3 IP: собирается в locals из `control_plane_count`.
- Локальный overlay: исправлен битый `deployment-php-fpm.patch.yaml` (duplicate port/два типа проб),
  увеличена локальная quota (php-fpm не влезал), k3d agents получают worker-метку, локальный Traefik —
  тот же `nodeSelector`, что и prod.
- Полный smoke test пересобран с нуля: k3d кластер пересоздан, `kubectl apply -k clusters/local`,
  rollout всех deployment, HTTP 200 через Traefik для `smoke.localhost` и `smart-rest.localhost`,
  NetworkPolicy проверена в обе стороны, HPA получают метрики. На локальный кластер вручную применён
  `clusters/prod/infrastructure/cert-manager` для проверки (не входит в `clusters/local`).

## Следующий безопасный шаг

1. Владелец заполняет реальные значения локально в `owner-inputs.local.env` или в password manager.
2. Создать Hetzner Object Storage bucket и уточнить S3 endpoint для `backend.tf`.
3. Создать локальный `infra/terraform/envs/prod/terraform.tfvars` с реальными значениями.
4. После этого запускать `terraform init` с remote backend в `infra/terraform/envs/prod`.

До реальных Hetzner данных можно продолжать локальную проверку:

```bash
bash scripts/local-validate.sh
```

Для полного smoke test нужен `k3d` и команды из `clusters/local/README.md`.

## Блокеры перед реальным apply

- Нет подтверждённого `HCLOUD_TOKEN` нового пустого Hetzner Project.
- Нет подтверждённых Object Storage S3 credentials/backend endpoint.
- Нужно проверить имя приватного интерфейса на тестовой VM перед боевым apply.

## Осталось до go-live (не блокирует apply инфраструктуры)

- Мониторинг/алерты (kube-prometheus-stack) — ставить до переключения клиентов, не после.
- Flux bootstrap (сейчас ручной `kubectl apply -k`) — проще завести до первого прод-apply.
- MariaDB-слой (отдельные VM, бэкапы) — Этап 5 плана, в Terraform ещё не описан.
- Заменить placeholder host `api.smart-rest.example.com` в ingress и `CHANGE_ME` теги образов.
- Hetzner CCM/CSI (Этап 3 плана) — применяются на живой кластер, в репо пока не зафиксированы.
