# Hetzner Prod Infra — мастер-план (Terraform + K3s HA + GitOps)

**Статус: это твой первый прод-кластер такого уровня. Документ написан с расчётом на то, что ошибка стоит
дорого — поэтому после каждого шага есть проверка "как понять, что всё ок", а не просто команда для запуска.
Не переходи к следующему этапу, пока проверка предыдущего не прошла.**

Старый кластер (smp, RKE1, k8s v1.26, 1 master + 4 worker) **не трогаем вообще** — не мигрируем, не
переключаем трафик, не переиспользуем токены/сети. Это полностью новый, независимый Hetzner Project и
независимый кластер.

Один кластер обслуживает **все** проекты (smart-rest, fitness, beauty, mootq-v2 и будущие) через отдельные
Kubernetes namespace — не через отдельные кластеры на каждый проект.

**Второй раунд ревью (июль 2026):** пройдено ещё раз целиком после первого раунда правок. Основные находки
этого раунда, помечены по тексту как «правка после второго раунда ревью»: (1) ingress-nginx с марта 2026
официально retired — заменён на встроенный в k3s Traefik, донастроенный под ту же схему (Этапы 2.1, 3.3, 3.4,
3.6, 4, 6.4); (2) явная ротация логов контейнеров через `--kubelet-arg` — функциональный эквивалент старого
фикса `/etc/docker/daemon.json` со smp, перенесённый под containerd (Этап 2.1); (3) отсутствие HA у MariaDB
теперь явно проговорено как осознанный компромисс, а не молчаливый пробел, плюс поправлен
`innodb_buffer_pool_size`, который не соответствовал собственному комментарию (Этап 5.1); (4) в CI/CD
добавлен тестовый gate и manual approval перед деплоем в общий на 4 проекта прод (Этап 7).

**Третий раунд ревью (июль 2026) — внешняя проверка нашла ещё пять мест, плюс усомнилась в источнике
находки (1) из второго раунда.** По retirement ingress-nginx — источник добавлен прямо в Этап 3.3
(два официальных поста kubernetes.io, включая совместное заявление Kubernetes Steering Committee), это не
было отозвано или перепутано, проверено повторно fetch'ем страницы напрямую. `v1.35.6+k3s1` тоже
перепроверен — реальный тег на k3s-io/k3s, релиз от 24 июня 2026 (см. Этап 2.1). Остальные находки этого
раунда, помечены как «правка после третьего раунда ревью»: (5) `--advertise-address` добавлен явно рядом с
`--node-ip` как защита от будущих сюрпризов, хотя дефолт и так корректен при отсутствии
`--node-external-ip` (Этап 2.1); (6) `k3s_version` — теперь реальная Terraform-переменная, а не просто
рекомендация в прозе (Этапы 1.2, 1.5, 2.1-2.3); (7) fallback-доступ к API через cp-2/cp-3 на случай, если
именно cp-1 недоступна — расширенный `--tls-san` и два дополнительных SSH-туннеля (Этапы 2.1, 2.2, 2.5);
(8) hostNetwork-конфигурация traefik теперь проверяется на уровне ОС и сквозным запросом, а не только по
статусу пода (Этап 3.3).

---

## Важное про названия (чтобы не путаться)

- **Hetzner Cloud Project** (в консоли Hetzner) — назови `smartrest-prod-v2` или похоже, тут только серверы/сеть/LB.
- **Git-репозиторий с инфраструктурой** — назови нейтрально, например `hetzner-prod-infra`. Он НЕ про
  smartrest конкретно, он про весь Hetzner-прод целиком (Terraform + манифесты для всех проектов).
- **Git-репозитории с кодом приложений** (smart-rest, fitness и т.д.) — остаются отдельными, как сейчас.
  Их CI/CD будет пушить изменения в `hetzner-prod-infra`, но сам код там не живёт.

```bash
mkdir -p ~/projects/hetzner-prod-infra
cd ~/projects/hetzner-prod-infra
git init
```

---

## Этап -1. Предварительный чек-лист (сделать ДО первой команды)

Это тот самый список, который отличает "получилось" от "получилось, но потом сломалось в проде". Пройдись
по каждому пункту, ничего не пропускай.

- [ ] Заведён **отдельный** Hetzner Cloud Project (не используется старый, где живёт smp-кластер).
- [ ] Создан **отдельный** SSH-ключ только под эту инфраструктуру:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/hetzner_prod_v2 -C "hetzner-prod-v2-deploy"
  ```
  Не переиспользуй личный `~/.ssh/id_rsa` для прод-серверов — если ключ утечёт из другого контекста,
  под угрозой окажется и прод.
- [ ] Записан твой текущий публичный IP для firewall (SSH только с него):
  ```bash
  curl -s https://ifconfig.me
  ```
  Если IP динамический (обычный домашний интернет) — учти, что при смене IP потеряешь SSH-доступ через
  firewall-правило. Варианты: держать правило на диапазон провайдера, использовать VPN с статическим IP,
  либо (проще для старта) временно разрешить более широкий диапазон и сузить позже.
- [ ] Домены, которые будешь использовать, уже куплены и ты можешь менять DNS-записи (доступ к
  регистратору/Cloudflare).
- [ ] Есть, где хранить секреты вне git (пароль от MariaDB root, k3s_token, hcloud_token) — минимум
  password-менеджер, в идеале — Vault/1Password. **Ничего из этого никогда не коммитится в git в открытом виде.**
- [ ] Понимание бюджета: посчитай примерную стоимость ДО создания (см. Приложение A — расчёт стоимости).
- [ ] Решено, где будет собираться Docker-образ (свой registry / GitHub Container Registry / Docker Hub
  private). В примерах ниже используется `registry.example.com` — замени на реальный.
- [ ] У тебя есть второй человек или хотя бы возможность подождать 24 часа перед реальным запуском под
  нагрузкой — не делай go-live поздно вечером в пятницу.

---

## Этап 0. Подготовка окружения (1 день)

### 0.1 Hetzner Cloud API token
```bash
# В консоли: новый Project -> Security -> API Tokens -> Generate -> Read & Write
export HCLOUD_TOKEN="xxxxx"

# Проверка, что токен реально работает и смотрит в правильный (новый, пустой) проект:
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers | jq .
```
**Проверка:** ответ должен быть `{"servers": []}` — пустой список, потому что проект новый. Если там уже
что-то есть — ты по ошибке взял токен от старого проекта. Остановись и разберись, прежде чем продолжать.

### 0.2 Установить локальные инструменты
```bash
# Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# hcloud CLI (полезно для быстрой проверки без консоли)
curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz
sudo mv hcloud /usr/local/bin/
hcloud context create prod-v2   # вставит токен, спросит имя
```
**Проверка:**
```bash
terraform version   # >= 1.5
kubectl version --client
helm version
flux --version
hcloud server list   # пусто, без ошибок авторизации
```

### 0.3 Структура репозитория
```bash
cd ~/projects/hetzner-prod-infra
mkdir -p infra/terraform/modules/{network,firewall,server,loadbalancer}
mkdir -p infra/terraform/envs/prod
mkdir -p infra/terraform/cloud-init
mkdir -p clusters/prod/infrastructure/{traefik,cert-manager,hcloud-ccm,hcloud-csi,monitoring,sealed-secrets}
mkdir -p clusters/prod/apps
```

```
hetzner-prod-infra/
  infra/terraform/
    modules/{network,firewall,server,loadbalancer}/
    envs/prod/{main.tf,variables.tf,backend.tf,outputs.tf}
    cloud-init/{control-plane.yaml.tpl,control-plane-join.yaml.tpl,worker.yaml.tpl}
  clusters/prod/
    flux-system/                <- генерируется flux bootstrap автоматически
    infrastructure/
      traefik/          <- HelmChartConfig + Middleware для встроенного k3s Traefik, см. Этап 3.3
      cert-manager/
      hcloud-ccm/
      hcloud-csi/
      monitoring/
      sealed-secrets/
    apps/
      smart-rest/
      fitness/        <- добавляется позже, по образцу smart-rest
      beauty/
      mootq/
```

### 0.4 .gitignore — обязательно до первого коммита
```bash
cat > .gitignore << 'EOF'
*.tfstate
*.tfstate.*
.terraform/
*.tfvars
!*.tfvars.example
.env
*.pem
*.key
!*.pub
kubeconfig*
EOF
git add .gitignore
git commit -m "chore: gitignore"
```
**Почему это критично:** `.tfvars` с реальными токенами или `.tfstate` (в нём могут быть секреты в открытом
виде) никогда не должны попасть в git-историю. Если случайно закоммитил секрет — недостаточно удалить файл
следующим коммитом, секрет всё равно останется в истории. Нужно ротировать сам секрет (перевыпустить токен).

**Правка после ревью: `.terraform.lock.hcl` — НЕ игнорируем, коммитим в git.** Изначально он был в списке
исключений, это неправильно. Lock-файл фиксирует конкретные версии и checksums провайдеров (`hcloud` и
т.д.) — без него `terraform init` у разных людей (или через полгода у тебя самого) может подтянуть другую
версию провайдера и получить другое поведение `apply` на, казалось бы, том же коде. Игнорировать нужно
только `.terraform/` (папку с бинарниками провайдеров — она тяжёлая и генерируется заново), а не сам
lock-файл.

---

## Этап 1. Terraform: сеть, firewall, серверы, LB (1-2 дня)

### 1.1 Backend для state — ОБЯЗАТЕЛЬНО удалённый, не локальный файл
Если state лежит только у тебя на ноутбуке и диск умрёт — ты теряешь возможность управлять инфраструктурой
через Terraform (сама инфра не пропадёт, но `terraform` перестанет "знать", что чем управляет).

Создай bucket в Hetzner Object Storage через консоль (Object Storage -> Create Bucket), включи
**версионирование** сразу.

`infra/terraform/envs/prod/backend.tf`:
```hcl
terraform {
  backend "s3" {
    bucket                      = "hetzner-prod-infra-tfstate"
    key                         = "prod/terraform.tfstate"
    region                      = "eu-central-1"
    endpoint                    = "https://fsn1.your-objectstorage.com"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
```

### 1.2 Provider и переменные
`infra/terraform/envs/prod/variables.tf`:
```hcl
variable "hcloud_token" {
  sensitive = true
}

variable "k3s_token" {
  sensitive   = true
  description = "Общий секрет для присоединения нод к кластеру. Генерировать: openssl rand -hex 32"
}

variable "k3s_version" {
  default     = "v1.35.6+k3s1"
  description = "ОБЯЗАТЕЛЬНО проверь на https://github.com/k3s-io/k3s/releases и https://kubernetes.io/releases/patch-releases/ прямо перед apply — значение по умолчанию тут устареет. Одно место вместо трёх — правка после третьего раунда ревью, см. пояснение в Этапе 2.1."
}

variable "control_plane_count" {
  default = 3   # ОБЯЗАТЕЛЬНО нечётное число (3 или 5) — так работает etcd quorum
}

variable "worker_count" {
  default = 4
}

variable "ssh_public_key_path" {
  default = "~/.ssh/hetzner_prod_v2.pub"
}

variable "allowed_ssh_ip" {
  description = "Твой публичный IP в формате x.x.x.x/32"
}
```

`infra/terraform/envs/prod/main.tf` (provider):
```hcl
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
```

Сгенерируй `k3s_token` один раз и сохрани в секрет-хранилище (не в git):
```bash
openssl rand -hex 32
```

### 1.3 Приватная сеть
```hcl
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
```

### 1.4 Firewall — по умолчанию всё закрыто, открываем только нужное

**Правка после ревью: разделяем firewall на control-plane и workers**, вместо одного общего. У
control-plane нет причин иметь открытые 80/443 вообще — туда никогда не должен идти прямой публичный
трафик (весь HTTP/HTTPS трафик обслуживают workers через ingress-контроллер — Traefik, см. Этап 3.3). Общий firewall на всех нодах — это
лишняя площадь атаки на CP без всякой пользы.
```hcl
resource "hcloud_firewall" "control_plane" {
  name = "control-plane-firewall"

  # SSH — только с твоего IP, и больше ничего
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.allowed_ssh_ip]
  }

  # 6443 намеренно не открываем даже на 10.10.0.0/16 в этом Hetzner-firewall (на публичном интерфейсе
  # implicit deny полностью блокирует внешний доступ). Внутри private network доступ регулируется уже
  # host-level ufw на самих нодах (Этап 2), а не этим Cloud Firewall — см. пояснение ниже.

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

  # 80/443 намеренно НЕ открываем публично здесь (правка после ревью — см. пояснение ниже).

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
```
**Правка после ревью — почему 80/443 больше не открыты публично на workers.** С `use_private_ip = true` на
LB target (Этап 1.6) весь трафик LB → worker идёт по приватной сети. Публичное правило 80/443 в таком виде
нужно было только для одного сценария — который на самом деле является дырой: он позволяет любому в
интернете обратиться напрямую на публичный IP конкретной worker-ноды в обход LB (в обход рейт-лимитов,
будущих WAF-правил на LB, и т.д.). Раз LB и так не использует публичный путь, держать его открытым не даёт
никакой пользы, только лишнюю поверхность. Закрываем.

**Важный нюанс:** flannel (внутрисетевой оверлей K3s) и межнодовый трафик k3s (10250 kubelet, 8472 VXLAN)
должны ходить свободно — но это внутри приватной сети `10.10.0.0/16`, куда извне доступа всё равно нет
(Hetzner Cloud Firewall на публичном интерфейсе тут вообще не участвует), поэтому явные правила под них не
нужны на уровне Hetzner Firewall. Порт 6443 не открыт нигде ни на CP, ни на workers на публичном
интерфейсе.

**Уточнение threat model после ревью (важно, чтобы не переоценивать защиту):** формулировка "единственный
путь к API — SSH-туннель" была неточной. Host-level `ufw` на нодах (Этап 2) содержит правило
`ufw allow from 10.10.0.0/16`, которое открывает ВСЕ порты (включая 6443) между любыми двумя нодами внутри
приватной сети — это сделано ради простоты (flannel/kubelet трафику нужно ходить свободно), но de facto
означает, что любая нода (или скомпрометированный под с доступом к сети ноды) внутри `10.10.0.0/16` технически
может обратиться к API напрямую по приватному IP, без всякого SSH-туннеля. SSH-туннель — единственный путь
для доступа **с твоего ноутбука снаружи приватной сети**, но не абсолютная гарантия "только через туннель"
в широком смысле. Если нужна более строгая модель — сузь `ufw allow from 10.10.0.0/16` до конкретных портов
(10250, 8472, 51820 при wireguard-бэкенде flannel, и т.д.) вместо бланковского разрешения; для старта это
приемлемый компромисс между простотой и строгостью, но осознанный, а не случайный.

### 1.5 SSH-ключ, placement group, control-plane и worker серверы
```hcl
resource "hcloud_ssh_key" "default" {
  name       = "hetzner-prod-v2-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# spread placement group разносит control-plane ноды по разным физическим хостам Hetzner —
# если один физический сервер Hetzner упадёт, не потеряешь сразу 2 из 3 control-plane
resource "hcloud_placement_group" "control_plane" {
  name = "cp-spread"
  type = "spread"
}

resource "hcloud_server" "control_plane" {
  count               = var.control_plane_count
  name                = "cp-${count.index + 1}"
  server_type         = "cpx31"
  image               = "ubuntu-24.04"
  location            = "fsn1"
  ssh_keys            = [hcloud_ssh_key.default.id]
  firewall_ids        = [hcloud_firewall.control_plane.id]
  placement_group_id  = hcloud_placement_group.control_plane.id

  network {
    network_id = hcloud_network.main.id
    ip         = "10.10.1.${10 + count.index}"
  }

  user_data = count.index == 0 ? templatefile("${path.module}/../../cloud-init/control-plane.yaml.tpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    private_ip  = "10.10.1.${10 + count.index}"
  }) : templatefile("${path.module}/../../cloud-init/control-plane-join.yaml.tpl", {
    k3s_token   = var.k3s_token
    k3s_version = var.k3s_version
    first_cp_ip = "10.10.1.10"
    private_ip  = "10.10.1.${10 + count.index}"
  })

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_placement_group" "workers" {
  name = "worker-spread"
  type = "spread"
}

resource "hcloud_server" "worker" {
  count               = var.worker_count
  name                = "worker-${count.index + 1}"
  server_type         = "cpx41"
  image               = "ubuntu-24.04"
  location            = "fsn1"
  ssh_keys            = [hcloud_ssh_key.default.id]
  firewall_ids        = [hcloud_firewall.workers.id]
  placement_group_id  = hcloud_placement_group.workers.id

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
```
**Правки после третьего раунда ревью:**
- `k3s_version = var.k3s_version` добавлен во все три вызова `templatefile()` — раньше версия K3s была
  захардкожена прямо в трёх `.tpl`-файлах (Этап 2.1-2.3), хотя проза рядом уже советовала вынести её в
  переменную. Теперь это реально сделано: один `variable "k3s_version"` в Этапе 1.2, подставляется через
  `${k3s_version}` в шаблонах. При апгрейде — правишь `terraform.tfvars` (или дефолт переменной) в одном
  месте, а не три `.tpl`-файла по отдельности.

**Правки после ревью:**
- `pathexpand(var.ssh_public_key_path)` вместо голого `file(var.ssh_public_key_path)` — Terraform не
  раскрывает `~` сам по себе, `file("~/.ssh/...")` может упасть с "no such file" в зависимости от того,
  откуда запускается `terraform apply`. `pathexpand` раскрывает `~` в реальный home-каталог надёжно.
- Приватный IP каждой ноды (`private_ip`) теперь передаётся в cloud-init явно из Terraform, а не
  вычисляется на самой ноде через `hostname -I | awk '{print $2}'` — подробности и почему это было хрупко
  см. в Этапе 2.1.
- `firewall_ids` теперь разные: `hcloud_firewall.control_plane.id` для control-plane,
  `hcloud_firewall.workers.id` для workers.

**Важно про `depends_on = [hcloud_server.control_plane]` у workers:** без этого Terraform может создавать
control-plane и worker ноды параллельно, и worker попытается присоединиться к кластеру, которого ещё нет.
Это одна из самых частых причин "почему воркер не появился в кластере" при первом запуске.

### 1.6 Load Balancer
```hcl
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
  count             = var.worker_count
  type              = "server"
  load_balancer_id  = hcloud_load_balancer.main.id
  server_id         = hcloud_server.worker[count.index].id
  use_private_ip    = true

  depends_on = [hcloud_load_balancer_network.main]
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
}
```
**Правки после ревью:**
- **`use_private_ip = true` добавлен явно.** Без этого параметра LB может маршрутизировать трафик на
  worker-ноды через их публичные IP вместо приватной сети — то есть трафик LB → worker шёл бы через
  публичный интернет туда-обратно вместо приватной сети, медленнее и без пользы от приватной сети вообще.
  Теперь, когда 80/443 закрыты в Hetzner Firewall на workers (см. Этап 1.4), это уже не опция, а
  необходимость — без `use_private_ip = true` LB просто не смог бы достучаться до backend.
- **`depends_on = [hcloud_load_balancer_network.main]` добавлен явно.** Без явной зависимости Terraform
  формально может попытаться создать `hcloud_load_balancer_target` с `use_private_ip = true` до того, как
  LB реально подключён к приватной сети (`hcloud_load_balancer_network`) — Terraform видит связь через
  `load_balancer_id` у обоих ресурсов, но это не гарантирует правильный порядок операций для конкретно
  network-attachment, который логически должен случиться раньше, чем targeting по приватному IP.
  `depends_on` убирает эту гонку явно, а не полагается на неявный вывод графа зависимостей.

`infra/terraform/envs/prod/outputs.tf`:
```hcl
output "lb_public_ip" {
  value = hcloud_load_balancer.main.ipv4
}

output "control_plane_ips" {
  value = hcloud_server.control_plane[*].ipv4_address
}

output "worker_ips" {
  value = hcloud_server.worker[*].ipv4_address
}
```

### 1.7 tfvars (НЕ коммитится, только пример в git)
`infra/terraform/envs/prod/terraform.tfvars.example`:
```hcl
hcloud_token   = "CHANGE_ME"
k3s_token      = "CHANGE_ME"
allowed_ssh_ip = "203.0.113.5/32"
```
Реальный `terraform.tfvars` создаёшь локально (он в `.gitignore`).

### 1.8 Применить — ПОШАГОВО, не одним махом
```bash
cd infra/terraform/envs/prod
terraform init
terraform validate          # синтаксис ок?
terraform plan -out=tfplan  # ВНИМАТЕЛЬНО прочитай план перед apply
```
**Проверка плана:** в выводе `terraform plan` посчитай ресурсы — должно быть ровно 3 control-plane + 4
worker + 1 network + 2 firewall (control-plane и workers отдельно) + 1 LB + связанные ресурсы. Если видишь
`-/+ destroy and recreate` для чего-то — остановись, разберись, почему. На первом запуске всё должно быть
только `+ create`, ничего не `destroy`.

```bash
terraform apply tfplan
```
**Проверка после apply:**
```bash
terraform output
hcloud server list        # должно быть видно cp-1, cp-2, cp-3, worker-1..4, status "running"
hcloud load-balancer list # статус "running", targets присвоены
```

---

## Этап 2. Bootstrap K3s HA (0.5-1 день)

### 2.0 Сначала проверь имя приватного интерфейса на тестовой VM — не полагайся на `enp7s0` вслепую

**Правка после ревью, важная про порядок действий.** Ниже cloud-init шаблоны используют `enp7s0` как имя
приватного интерфейса — это типичное имя на Hetzner Ubuntu-образах, но не гарантированное для конкретного
`server_type`/образа/версии Ubuntu, которые ты выберешь. Прежде чем прописывать это имя в шаблоны, которые
пойдут в боевой Terraform apply на 7 нод, проверь его на одной дешёвой одноразовой VM того же типа и
образа:
```bash
# Создай одну тестовую ноду того же server_type/image, что и боевые, в той же приватной сети
hcloud server create --name test-iface-check --type cpx31 --image ubuntu-24.04 \
  --network hetzner-prod-net --ssh-key hetzner-prod-v2-deploy

ssh -i ~/.ssh/hetzner_prod_v2 root@<публичный IP тестовой ноды>
ip -br addr
# Смотри, какой интерфейс имеет адрес из диапазона 10.10.0.0/16 — это и есть нужное имя

# Удали тестовую ноду сразу после проверки, чтобы не платить за неё:
hcloud server delete test-iface-check
```
Если реальное имя совпало с `enp7s0` — можно использовать шаблоны ниже как есть. Если нет — замени
`enp7s0` на реальное имя интерфейса **во всех трёх cloud-init шаблонах ниже**, прежде чем запускать
`terraform apply` на боевую конфигурацию. Тестовая VM с CPX31 стоит копейки за час — потратить полчаса на
эту проверку значительно дешевле, чем разбираться, почему flannel не поднялся, уже на 7 реальных нодах.

### 2.1 cloud-init для первой control-plane ноды
`infra/terraform/cloud-init/control-plane.yaml.tpl`:
```yaml
#cloud-config
package_update: true

runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${k3s_token} sh -s - server \
      --cluster-init \
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
```
**Правки после третьего раунда ревью (внешняя проверка нашла ещё несколько мест):**
- **`--advertise-address=${private_ip}` добавлен явно.** По официальной CLI-документации K3s
  (https://docs.k3s.io/cli/server) у `--advertise-address` дефолт — `node-external-ip/node-ip`: то есть он и
  так уже брал бы значение `--node-ip` автоматически, поскольку `--node-external-ip` в этом плане нигде не
  задаётся. Прямо сейчас это не баг — просто неявная зависимость от порядка приоритетов в дефолтах. Явная
  строка ничего не чинит, но защищает от будущего сюрприза: если кто-то позже добавит `--node-external-ip`
  ради чего-то другого (например, чтобы у ноды в лейблах появился публичный IP), advertise-address молча
  переключится на публичный IP вслед за ним, если не зафиксирован отдельно. Дешёвая страховка на будущее.
- **`--tls-san=10.10.1.11` и `--tls-san=10.10.1.12` добавлены к уже существующему `10.10.1.10`.** Раньше в
  SAN-листе сертификата был только IP первой control-plane ноды — если именно cp-1 недоступна, достучаться
  напрямую до cp-2/cp-3 по HTTPS с валидным сертификатом было нечем, хотя сам кластер (embedded etcd, 3
  ноды) пережил бы потерю одной ноды спокойно. `--tls-san` можно указывать несколько раз
  (https://docs.k3s.io/cli/server) — теперь сертификат покрывает приватные IP всех трёх control-plane нод, и
  fallback-доступ через cp-2/cp-3 реально работает, не только теоретически. Та же тройка `--tls-san` нужна и
  в Этапе 2.2 (join-нод) для консистентности.
- **`INSTALL_K3S_VERSION=${k3s_version}` — теперь переменная, не хардкод.** Раньше строка `v1.35.6+k3s1`
  была прописана впрямую в трёх местах; теперь она приходит из Terraform-переменной `k3s_version` (Этап 1.2),
  подставляется через `templatefile()` (Этап 1.5) — правишь один раз, а не три .tpl-файла по отдельности.
- **Проверка конкретно `v1.35.6+k3s1` — тег существует.** На момент этого раунда ревью (начало июля 2026)
  `v1.35.6+k3s1` — реальный релиз k3s-io/k3s, вышел 24 июня 2026
  (https://github.com/k3s-io/k3s/releases/tag/v1.35.6+k3s1), актуальный latest на v1.35.X ветке. Это не
  повод перестать перепроверять перед реальным apply (см. следующий пункт) — просто на сегодняшний день
  число в дефолте переменной корректно, а не выдумано.
- **`--tls-san=10.10.1.10` — это приватный IP самой control-plane ноды, НЕ LB IP.** LB из Этапа 1.6 слушает
  только 80/443 и таргетит worker-ноды, он не проксирует 6443 и не знает о control-plane вообще —
  использовать его IP в `--tls-san` и в kubeconfig не будет работать физически. Если позже понадобится
  публичный вход в API — заводи отдельный LB-сервис на 6443 с таргетом именно на control-plane, отдельно
  от общего LB воркеров, и добавляй его IP в `--tls-san` дополнительной строкой.
- `INSTALL_K3S_VERSION` зафиксирован через переменную `k3s_version` (Kubernetes 1.35, поддержка до конца
  февраля 2027 по официальному графику релизов — https://kubernetes.io/releases/patch-releases/). Без явной
  версии `get.k3s.io` ставит текущий latest/stable на момент запуска скрипта — и при пересоздании ноды через
  месяц (например, после сбоя) можно получить другую версию K3s, чем на остальных нодах кластера, что ломает
  совместимость. **Важно: версии Kubernetes выходят из поддержки каждые ~14 месяцев** (K8s 1.33, например,
  потерял поддержку 28 июня 2026, подтверждено на https://kubernetes.io/releases/1.33/) — прежде чем
  применять этот план, зайди на https://kubernetes.io/releases/patch-releases/ и
  https://github.com/k3s-io/k3s/releases и убедись, что выбранная версия всё ещё в активной поддержке (не
  в maintenance mode и тем более не EOL). Значение переменной `k3s_version` (Этап 1.2) — один источник
  правды на все три cloud-init шаблона, редактировать три файла по отдельности больше не нужно.
- `package_upgrade: true` убран. На первом bootstrap апгрейд пакетов может неожиданно затянуть установку,
  перезапустить системные сервисы или упереться в apt lock прямо во время старта k3s — плохое время для
  сюрпризов. Образ Ubuntu 24.04 и так достаточно свежий; security-обновления настраиваются отдельно через
  `unattended-upgrades` уже после того, как кластер поднялся и стабилен (см. Приложение C).
- `--write-kubeconfig-mode` убран вообще — default в K3s это `600` (владелец только root), а не `644`.
  644 делает файл с полными admin-правами на кластер читаемым для ЛЮБОГО локального пользователя ноды —
  лишний риск на проде без причины. Мы логинимся по SSH как root, так что `600` не мешает забрать
  kubeconfig в Этапе 2.5 — `cat` от имени root файл с правами 600 читает нормально.
- **`ufw allow 80/tcp` и `443/tcp` убраны с control-plane нод — важная правка.** Они были в первой версии
  плана по инерции (скопированы с worker-шаблона), но control-plane никогда не должна принимать
  HTTP/HTTPS-трафик напрямую — весь трафик приложений идёт через ingress-контроллер на workers. Открытые 80/443
  на CP не давали никакой функциональности, только увеличивали площадь атаки на самые критичные ноды
  кластера (там живёт etcd). На control-plane host-level firewall теперь пропускает только SSH и трафик
  внутри приватной сети.
- **`--node-taint=node-role.kubernetes.io/control-plane:NoSchedule` — добавлен, важная правка.** В K3s (в
  отличие от kubeadm-кластеров) server-ноды **schedulable по умолчанию** — то есть без этого тейнта твои
  приложения могут случайно уехать на control-plane ноду, конкурируя за ресурсы с etcd/kube-apiserver, и
  memory-hungry под может там же уронить etcd. Тейнт закрывает control-plane для обычных workloads; все
  application Deployment'ы (Этап 6) идут на worker-ноды по умолчанию, никаких дополнительных tolerations
  им не нужно.
- **`--disable-cloud-controller` и `--kubelet-arg=cloud-provider=external` — добавлены, важная правка.**
  K3s из коробки включает свой встроенный (in-tree) cloud-controller. Мы ставим внешний Hetzner CCM в
  Этапе 3 — если не отключить встроенный явно, по официальным K3s docs это может привести к конфликту за
  порт 10258 между двумя CCM, либо внешний CCM просто не возьмёт на себя часть функций. Здесь есть побочный
  эффект, который важно понимать заранее: после этих флагов и ДО того, как заработает внешний CCM (Этап 3),
  все ноды получат временный тейнт `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` и не будут
  принимать обычные поды (включая CoreDNS) — это ожидаемо и нормально, тейнт снимается автоматически, как
  только CCM из Этапа 3 успешно стартует и опознает ноды. Если между Этапом 2 и Этапом 3 проходит много
  времени — не пугайся, что `kubectl get pods -n kube-system` показывает Pending, это временное состояние.
- **`--node-ip=${private_ip}` вместо `$(hostname -I | awk '{print $2}')` — важная правка.** Приватный IP
  теперь передаётся из Terraform явным значением, а не вычисляется на самой ноде через `hostname -I`,
  которая просто перечисляет все IP интерфейсов в порядке, зависящем от их появления в системе — этот
  порядок не гарантирован и может отличаться между нодами или после апгрейда ОС. Точное значение из
  Terraform надёжнее любого вычисления на месте.
- **`--flannel-iface=enp7s0` вместо `eth1` — важная правка.** Реальное имя приватного сетевого интерфейса
  на Hetzner Cloud серверах (Ubuntu, systemd-предсказуемые имена) — как правило `enp7s0`, не `eth1`.
  `eth1` — это классическая Debian-стиль нумерация, которая на современных Ubuntu-образах Hetzner обычно
  не используется. Имя проверено заранее на тестовой VM в Этапе 2.0 — **если ты пропустил этот шаг, вернись
  и сделай его прежде, чем запускать apply на боевую конфигурацию**, не полагайся на `enp7s0` вслепую.

### 2.2 cloud-init для 2-й/3-й control-plane ноды
`infra/terraform/cloud-init/control-plane-join.yaml.tpl`:
```yaml
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
```
`--disable traefik` тут той же природы, что и в Этапе 2.1, и убран по той же причине (см. правку там) —
здесь просто нечего было убирать явно, кроме единообразия: на join-нодах traefik и так не переустанавливается
повторно, это чисто server-флаг для самого первого старта. `--advertise-address` и полный список `--tls-san`
из трёх приватных IP — по тем же причинам, что в Этапе 2.1 (правки после третьего раунда ревью), повторены
здесь для консистентности между всеми server-нодами.

### 2.3 cloud-init для worker-нод
`infra/terraform/cloud-init/worker.yaml.tpl`:
```yaml
#cloud-config
package_update: true

runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${k3s_token} K3S_URL=https://${cp_ip}:6443 sh -s - agent \
      --kubelet-arg=cloud-provider=external \
      --kubelet-arg=container-log-max-size=50Mi \
      --kubelet-arg=container-log-max-files=3 \
      --node-ip=${private_ip} \
      --node-label=node-role.kubernetes.io/worker=true \
      --flannel-iface=enp7s0
  - ufw allow from 10.10.0.0/16
  - ufw allow 22/tcp
  - ufw --force enable
```
`--kubelet-arg=cloud-provider=external` нужен и на worker-нодах тоже — кublet на любой ноде, где включён
external cloud-provider режим, должен знать об этом, иначе кластер окажется в смешанном состоянии. Ротация
логов контейнеров (`container-log-max-size`/`container-log-max-files`) нужна на worker-нодах даже больше,
чем на control-plane — именно там крутятся прикладные поды, включая тот, что когда-то на smp устроил
disk pressure. `cp_ip` тут по-прежнему `10.10.1.10` (только cp-1) — если cp-1 недоступна именно в момент
пересоздания worker-ноды, `K3S_URL` не достучится; на практике worker и так подключается к живому кластеру
через уже работающий flannel/etcd остальных нод после первого хендшейка, но если хочешь совсем убрать эту
точку отказа при пересоздании worker-нод — вынеси `cp_ip` в `for_each`/`random_shuffle` по всем трём
приватным IP control-plane, это уже отдельная доработка Terraform-кода, не показанная здесь.
`--node-label=node-role.kubernetes.io/worker=true` нужен не для Kubernetes как такового, а для нашей
дальнейшей донастройки Traefik в Этапе 3.3: ingress-контроллер должен запускаться только на worker-нодах,
а не "где получится". Без явного worker-label пришлось бы полагаться только на taint control-plane, но chart
может добавить tolerations в будущей версии. Явный `nodeSelector` в Traefik + явный label на workers делает
placement предсказуемым.

**Версия K3s (`INSTALL_K3S_VERSION`) теперь берётся из единой Terraform-переменной `k3s_version` (Этап 1.2,
подставляется через `templatefile()` в Этапе 1.5) — правка после третьего раунда ревью.** Раньше это было
только рекомендацией в тексте, без фактической реализации: строка `v1.35.6+k3s1` была прописана впрямую в
трёх `.tpl`-файлах, и апгрейд версии означал редактировать три места и не забыть ни одного. Теперь редактируешь
одну переменную.

**Почему именно так:** `--cluster-init` только на первой control-plane ноде — она создаёт новый etcd
кластер. Остальные две подключаются через `--server https://<ip первой>:6443`. Если перепутать и на всех
трёх поставить `--cluster-init` — получишь 3 разных изолированных кластера вместо одного HA.

### 2.4 Дать нодам время подняться, затем проверить
```bash
sleep 120   # cloud-init + установка k3s занимает 1-3 минуты на ноду
```

### 2.5 SSH-туннель и kubeconfig (единственный способ доступа к API)

**Важно:** LB из Этапа 1.6 слушает только 80/443 и таргетит worker-ноды — он НЕ проксирует 6443 и не
таргетит control-plane. Использовать LB IP для доступа к API не будет работать физически. Приватный IP
control-plane (`10.10.1.10`) тоже недоступен напрямую с ноутбука — это приватная сеть, увидеть его без VPN
или туннеля нельзя. Правильная последовательность — сразу через SSH-туннель, без промежуточных шагов с
приватным IP в кубконфиге:

Сначала настрой туннель:
```bash
# ~/.ssh/config
Host hetzner-prod-jump
  HostName <cp-1-public-ip>
  User root
  IdentityFile ~/.ssh/hetzner_prod_v2
  LocalForward 6443 10.10.1.10:6443

# Fallback, если cp-1 недоступна — правка после третьего раунда ревью, см. пояснение ниже
Host hetzner-prod-jump-cp2
  HostName <cp-2-public-ip>
  User root
  IdentityFile ~/.ssh/hetzner_prod_v2
  LocalForward 6443 10.10.1.11:6443

Host hetzner-prod-jump-cp3
  HostName <cp-3-public-ip>
  User root
  IdentityFile ~/.ssh/hetzner_prod_v2
  LocalForward 6443 10.10.1.12:6443
```
**Правка после третьего раунда ревью — раньше runbook давал только один путь к API, завязанный на cp-1.**
Сам кластер (embedded etcd, 3 ноды) переживёт потерю cp-1 спокойно — etcd quorum держат оставшиеся cp-2/cp-3.
Но если единственный задокументированный способ достучаться до API — это туннель именно через cp-1 к
IP именно cp-1, то при падении cp-1 кластер жив, а доступ по этому runbook сломан, пока кто-то не
сообразит на месте, как подключиться иначе. Два дополнительных `Host`-блока выше — то же самое, но через
cp-2/cp-3 и на их собственный приватный IP (не на IP cp-1). Это сработает только если `--tls-san` у всех
control-plane нод покрывает все три приватных IP (Этап 2.1/2.2 — уже поправлено), иначе TLS-хендшейк
до cp-2/cp-3 напрямую упадёт по несовпадению сертификата. Использование — то же самое, что и обычно, просто
с другим именем хоста:
```bash
ssh -N hetzner-prod-jump-cp2 &
# kubeconfig после этого тот же самый — server: https://127.0.0.1:6443 не меняется,
# меняется только то, какая физическая нода стоит за туннелем
```
```bash
ssh -N hetzner-prod-jump &
```
Затем забери kubeconfig и сразу пропиши в нём локальный конец туннеля (`127.0.0.1`), а не приватный IP:
```bash
ssh -i ~/.ssh/hetzner_prod_v2 root@<cp-1-public-ip> cat /etc/rancher/k3s/k3s.yaml > ~/.kube/hetzner-prod-v2.yaml
chmod 600 ~/.kube/hetzner-prod-v2.yaml
# server: в файле уже https://127.0.0.1:6443 — трогать не нужно, k3s.yaml по умолчанию так и пишет
export KUBECONFIG=~/.kube/hetzner-prod-v2.yaml
```
С этого момента `kubectl` работает, только пока запущен туннель (`ssh -N hetzner-prod-jump &` в фоне).
Порт 6443 закрыт на публичном интерфейсе полностью — это и есть контроль доступа к API снаружи. Внутри
приватной сети ситуация чуть менее строгая, см. уточнение threat model в Этапе 1.4.

**Проверка (это самая важная проверка на всём этапе 2):**
```bash
kubectl get nodes -o wide
```
Ожидаемый результат: 3 ноды с ролью `control-plane,etcd,master` (с тейнтом из Этапа 2.1/2.2, см.
`kubectl describe node cp-1 | grep Taints`) и 4 ноды с ролью `<none>` (workers), все в статусе `Ready`.
Если хоть одна нода `NotReady` дольше 5 минут — не двигайся дальше, разбирайся:
```bash
ssh -i ~/.ssh/hetzner_prod_v2 root@<ip проблемной ноды>
journalctl -u k3s -f          # для control-plane
journalctl -u k3s-agent -f    # для worker
```

**Проверка etcd (исправлено после ревью):** в K3s embedded etcd работает как часть процесса `k3s`, а не
как отдельный статический pod с лейблом `component=etcd` (это паттерн RKE2/kubeadm, в K3s его нет —
команда `kubectl get pods -l component=etcd` вернёт пустоту). Правильная проверка — через API server или
`etcdctl` с сертификатами прямо на хосте:
```bash
# Через kubectl (проще, без прямого обращения к etcd):
kubectl get --raw='/readyz?verbose' | grep etcd

# Или напрямую etcdctl на любой control-plane ноде (точнее, показывает конкретные endpoint'ы):
ssh -i ~/.ssh/hetzner_prod_v2 root@<cp-1-ip>
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  endpoint health --cluster --write-out=table
```
(K3s не кладёт `etcdctl` в PATH — он встроен в бинарник `k3s`; если команды `etcdctl` нет отдельно,
качай её той же версии с https://github.com/etcd-io/etcd/releases и указывай сертификаты вручную, как
выше.) Ожидай `healthy`/`true` для всех трёх endpoint'ов.

Дополнительно проверь снапшоты (сама возможность делать snapshot — тоже косвенный признак того, что etcd
в порядке):
```bash
k3s etcd-snapshot ls
```

### 2.6 Персональный доступ с ограниченными правами (не тащить root/admin kubeconfig на каждый ноутбук)
Kubeconfig из 2.5 имеет полные `cluster-admin` права — это нормально для первичной настройки, но не для
повседневной работы, особенно если позже появится второй человек с доступом. Заведи себе (и любому другому
человеку) отдельный `ServiceAccount` с урезанными правами через `ClusterRoleBinding`/`RoleBinding` на
конкретные namespace, и раздавай именно такие kubeconfig, а не root-файл из `/etc/rancher/k3s/k3s.yaml`.
Туннель из 2.5 при этом остаётся тем же самым — просто `server:` в персональном kubeconfig тоже будет
`https://127.0.0.1:6443`, а разница только в правах внутри самого файла.

---

## Этап 3. Инфраструктурные компоненты кластера (1 день)

### 3.1 Hetzner Cloud Controller Manager

**Важная поправка после ревью.** У Hetzner CCM два режима манифеста: `ccm.yaml` (базовый — только node
metadata/providerID и управление Service типа LoadBalancer) и `ccm-networks.yaml` (дополнительно включает
route controller — Kubernetes сам управляет маршрутами внутри Hetzner Network, но **это работает только
если Pod CIDR — часть Hetzner network range, и предполагает CNI без overlay** (native routing), по
официальным примечаниям Hetzner community docs. Мы остаёмся на flannel с дефолтным VXLAN-бэкендом
(overlay, Pod CIDR `10.42.0.0/16` — отдельный от Hetzner network `10.10.0.0/16`, и это осознанно, менять
не нужно) — значит route controller из `ccm-networks.yaml` тут просто неприменим и может создать неверные
маршруты. Используем базовый `ccm.yaml`.

**Критично про версию — не бери старый пин.** У Hetzner CCM есть официальное предупреждение: версии
**≤ v1.30.0 сломаются** после того, как поле `server.datacenter` будет удалено из Hetzner Cloud API
(объявленный дедлайн — после июля 2026, то есть уже сейчас или очень скоро). Всегда бери актуальный релиз
на момент apply, не полагайся на цифру, зафиксированную в этом документе месяцы назад — она успеет
устареть. Получи и зафиксируй актуальный тег прямо перед применением:
```bash
CCM_VERSION=$(curl -s https://api.github.com/repos/hetznercloud/hcloud-cloud-controller-manager/releases/latest | jq -r .tag_name)
echo "Актуальная версия CCM: $CCM_VERSION"   # убедись, что это НЕ v1.30.0 и старше

kubectl -n kube-system create secret generic hcloud \
  --from-literal=token=$HCLOUD_TOKEN

kubectl apply -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/${CCM_VERSION}/ccm.yaml
```
Зафиксируй итоговый `$CCM_VERSION` как обычный текст в своём `README`/runbook репозитория (не как
динамическую команду в манифесте) — воспроизводимость важнее автоматического "всегда самое новое", но сам
номер должен браться из проверки на момент реального apply, а не переписываться бездумно из старого
документа. Ключ `network=` в секрете для базового режима не нужен — он обязателен только для
networks-режима, который мы сознательно не используем.

**Проверка:**
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=hcloud-cloud-controller-manager
# статус Running, 0 restarts
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'
# у каждой ноды должен появиться provider ID вида hcloud://<id>
```

### 3.2 Hetzner CSI

**Правка после ревью:** манифест тянулся из ветки `main` (`raw.githubusercontent.com/.../main/...`) — то
есть при каждом повторном применении можно получить другую версию без предупреждения, это тот же риск
непредсказуемости, что и с `INSTALL_K3S_VERSION` без пина. Фиксируем на конкретный релизный тег так же, как
CCM выше:
```bash
CSI_VERSION=$(curl -s https://api.github.com/repos/hetznercloud/csi-driver/releases/latest | jq -r .tag_name)
echo "Актуальная версия CSI: $CSI_VERSION"

kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/${CSI_VERSION}/deploy/kubernetes/hcloud-csi.yml
```
**Проверка:**
```bash
kubectl get storageclass
# должен появиться "hcloud-volumes"
```
**Важное ограничение, держи в голове:** Hetzner Volume через CSI — это ReadWriteOnce, привязан к одной
ноде, без встроенных snapshot/backup от Hetzner. НЕ используй его для MariaDB/Redis данных — только для
временных/некритичных данных приложения. Основные БД — на отдельных VM (Этап 5).

### 3.3 Ingress-контроллер — встроенный в k3s Traefik (не ingress-nginx)

**Почему не ingress-nginx — коротко, подробное обоснование см. в правке к Этапу 2.1.** Проект
`kubernetes/ingress-nginx` officially retired с марта 2026 — новых релизов, багфиксов и патчей безопасности
для него больше не будет. Источники (официальные, не блог третьей стороны):
https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/ (анонс от Kubernetes SIG Network и Security
Response Committee, 11 ноября 2025) и https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/
(повторное совместное заявление Kubernetes Steering Committee, 29 января 2026, подтверждает срок и
подчёркивает риск для тех, кто останется). Ставить ingress-nginx сейчас как компонент, который примет 100%
внешнего трафика для всех проектов, значило бы с первого дня сидеть на неподдерживаемом ПО. K3s и так уже
включает Traefik v3 (активно поддерживается, из коробки умеет Gateway API) — дешевле донастроить его под ту
же схему, что раньше была у ingress-nginx, чем ставить сторонний EOL-проект в новый кластер.

**Нюанс, из-за которого просто "оставить дефолт" не сработает.** Дефолтный Service у traefik в k3s —
`LoadBalancer` через встроенный ServiceLB (Klipper), а внутренние порты чарта — `8000`/`8443`, не `80`/`443`.
У нас ServiceLB уже отключён (`--disable servicelb` в Этапе 2 — намеренно, вместо него Terraform-managed
Hetzner LB), а сам LB (Этап 1.6) целится строго в порты `80`/`443` на worker-нодах. Без явного
переопределения портов и типа Service traefik просто не будет слушать там, куда бьёт LB, — трафик молча не
дойдёт.

K3s не даёт редактировать `/var/lib/rancher/k3s/server/manifests/traefik.yaml` напрямую — при каждом
рестарте k3s перезатирает этот файл дефолтами. Донастройка идёт через отдельный ресурс `HelmChartConfig`,
применяется обычным `kubectl apply` на уже поднятый кластер (ноды уже есть с Этапа 2, traefik на них уже
работает с дефолтными портами — этот шаг просто донастраивает его):

```yaml
# clusters/prod/infrastructure/traefik/helmchartconfig.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik              # имя ДОЛЖНО совпадать с именем встроенного HelmChart "traefik"
  namespace: kube-system      # traefik живёт в kube-system, а не в своём namespace, как было у ingress-nginx
spec:
  valuesContent: |-
    deployment:
      kind: DaemonSet
    nodeSelector:
      node-role.kubernetes.io/worker: "true"
    service:
      type: ClusterIP
    hostNetwork: true
    ports:
      web:
        port: 80
      websecure:
        port: 443
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 1
```
```bash
kubectl apply -f clusters/prod/infrastructure/traefik/helmchartconfig.yaml
```
`updateStrategy` тут не косметика: без него на части версий чарта rolling update с `hostNetwork: true`
подвисает (новый под не может занять хост-порт, пока старый его не освободил). Полный список опций — в
`values.yaml` чарта traefik именно той версии, что идёт в комплекте с твоей версией k3s (лежит на ноде в
`/var/lib/rancher/k3s/server/static/charts/` после bootstrap).

**Проверка:**
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide
# по одному pod на каждой worker-ноде, 0 pod на cp-*; placement фиксируется nodeSelector'ом выше
kubectl get ingressclass
# должен быть класс "traefik"
kubectl -n kube-system get ds traefik -o yaml | grep -A8 nodeSelector
# должен быть node-role.kubernetes.io/worker: "true"
```
**Правка после финального ревью:** раньше план полагался на то, что Traefik не попадёт на control-plane из-за
taint. Это верно только пока chart не добавляет подходящий toleration. Для компонента, который слушает
hostNetwork-порты 80/443, лучше не оставлять placement на поведение чарта: workers получают явный label в
Этапе 2.3, а Traefik получает `nodeSelector` на этот label. Если после apply видишь pod Traefik на `cp-*` —
остановись и исправь placement до переключения DNS.

**Правка после третьего раунда ревью — двух проверок выше недостаточно, они не ловят конкретно проблемы
`hostNetwork`.** Поды могут быть `Running`, а порт при этом — не занят физически (например, если
`ports.web.port`/`ports.websecure.port` не применились из `HelmChartConfig`, или порт занят чем-то другим).
Проверь на уровне ОС и сквозным запросом до переключения DNS на прод (тот же приём, что уже используется в
Этапе 6.5 для проверки нового проекта):
```bash
# на самой worker-ноде — порты 80/443 реально слушаются процессом traefik, не просто "под Running":
ssh -i ~/.ssh/hetzner_prod_v2 root@<worker-public-ip>
ss -lntp | grep -E ':80|:443'

# с ноутбука — сквозной запрос через реальный LB, минуя DNS:
curl --resolve test.example.com:443:<LB_IP> https://test.example.com/health
```
Если `ss` ничего не показывает на 80/443 — `HelmChartConfig` не применился или применился с ошибкой; смотри
`kubectl -n kube-system logs -l app.kubernetes.io/name=traefik` и `kubectl -n kube-system get helmchart
traefik -o yaml` (поле `status`) прежде чем разбираться дальше.

**Rate limiting вместо nginx-аннотаций.** У ingress-nginx это были `nginx.ingress.kubernetes.io/limit-rps` /
`limit-connections` прямо на Ingress. У traefik готовых аннотаций для этого на голом `Ingress` нет — нужен
отдельный CRD `Middleware` плюс ссылка на него аннотацией `traefik.ingress.kubernetes.io/router.middlewares`.
Пример и применение к конкретному проекту — Этап 6.4.

### 3.4 cert-manager
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true
```
**Проверка:**
```bash
kubectl -n cert-manager get pods
# cert-manager, cert-manager-cainjector, cert-manager-webhook — все Running
```

ClusterIssuer — **сначала staging**, чтобы не упереться в rate limit Let's Encrypt (5 неудачных попыток
на домен в неделю на прод-issuer, если что-то настроено неправильно):
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: devops@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress:
            class: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: devops@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: traefik
```
Проверь на staging issuer на тестовом поддомене, сертификат выпустился без ошибок (`kubectl describe
certificate`), только потом меняй `letsencrypt-staging` на `letsencrypt-prod` в реальном Ingress. Класс
`traefik` тут — правка вместо `nginx` из первой версии плана (Этап 3.3).

### 3.5 sealed-secrets (нужно ДО того, как класть секреты приложений в Git через Flux)
```bash
SEALED_SECRETS_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name)
echo "Актуальная версия sealed-secrets: $SEALED_SECRETS_VERSION"

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml
```
Зафиксируй итоговый `$SEALED_SECRETS_VERSION` в runbook/README так же, как CCM/CSI. Не используй
`releases/latest/download/controller.yaml` в GitOps-манифестах: сегодня это один controller, через месяц —
другой, и rebuild кластера уже не будет воспроизводимым.

**Проверка:**
```bash
kubectl -n kube-system get pods -l name=sealed-secrets-controller
```

### 3.6 Базовые NetworkPolicy (изоляция между namespace)
Без этого любой pod в любом namespace может достучаться до любого другого — в том числе fitness до БД
smart-rest, если случайно неправильно настроить Service.

**Уточнение:** K3s включает встроенный NetworkPolicy-контроллер (kube-router) вместе с flannel по
умолчанию — `NetworkPolicy` реально работают "из коробки", отдельный CNI (Calico/Cilium) под это ставить
не нужно.

Default-deny ingress — обязательный минимум:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: fitness-prod
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

Этого недостаточно самого по себе — без egress-правил под DNS pod вообще не сможет резолвить имена сервисов
(включая собственный кластерный DNS), поэтому egress DNS разрешаем явно первым делом:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: fitness-prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
```
Разрешить web-поду ходить наружу только к MariaDB (10.10.1.100) и в интернет по 443 (Object Storage, внешние API):
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-egress
  namespace: fitness-prod
spec:
  podSelector:
    matchLabels: {app: fitness-web}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: {cidr: 10.10.1.100/32}   # MariaDB
      ports:
        - {protocol: TCP, port: 3306}
    - to:
        - ipBlock: {cidr: 0.0.0.0/0}
      ports:
        - {protocol: TCP, port: 443}
```
И разрешить ingress только от ingress-контроллера к веб-сервису:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-traefik
  namespace: fitness-prod
spec:
  podSelector:
    matchLabels: {app: fitness-web}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {app.kubernetes.io/name: traefik}
      ports:
        - {protocol: TCP, port: 80}
```
**Правка после второго раунда ревью:** было `namespaceSelector` на `ingress-nginx` — с переходом на
встроенный traefik (Этап 3.3) такого namespace просто не существует, traefik живёt в `kube-system`. Простая
замена namespace на `kube-system` сама по себе была бы избыточно широкой: `kube-system` — это ещё и CoreDNS,
CCM, CSI, metrics-server и т.д., и без дополнительного фильтра любой под оттуда получил бы доступ к
`fitness-web`. Добавлен `podSelector` на `app.kubernetes.io/name: traefik` внутри того же `from`-блока —
`namespaceSelector` и `podSelector` в одном элементе списка `from` комбинируются через "И", а не "ИЛИ", так
что правило по-прежнему пускает только сам traefik, как и было задумано изначально.

Все четыре файла применяются в каждый namespace приложения (Этап 6), с заменой namespace/label под
конкретный проект.

---

## Этап 4. GitOps — Flux (0.5 дня)

```bash
export GITHUB_TOKEN=<personal access token с правами repo>
flux bootstrap github \
  --owner=<your-github-username-or-org> \
  --repository=hetzner-prod-infra \
  --branch=main \
  --path=clusters/prod \
  --personal
```
**Проверка:**
```bash
flux check
kubectl -n flux-system get pods
# все компоненты (source-controller, kustomize-controller, helm-controller, notification-controller) Running
```

**Важно после ревью:** CCM, CSI, cert-manager, sealed-secrets в Этапе 3 были поставлены вручную через
`kubectl apply`/`helm install` — это нормально для самого первого bootstrap (кластер ещё не существовал,
Flux ставить было некуда). Traefik сюда тоже относится, хоть и появился не через `helm install`, а был
донастроен через `HelmChartConfig` (Этап 3.3) поверх того, что уже сам поставил k3s при старте. Финальное
состояние этих компонентов должно быть переведено под Flux как `HelmRelease`/`Kustomization` в
`clusters/prod/infrastructure/`, иначе получится drift: в кластере одно, в git — ничего, и следующий человек
(или ты сам через полгода) не поймёт, откуда что взялось и как это переустановить в случае потери кластера.
Сделай это сразу после Этапа 4, до перехода к Этапу 5:
```yaml
# clusters/prod/infrastructure/traefik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmchartconfig.yaml   # тот самый файл из Этапа 3.3
```
**Важно про traefik конкретно:** `HelmChartConfig` — не Helm-чарт сам по себе (сам чарт traefik ставит k3s
при бутстрапе, не Flux), поэтому сюда не подходит `HelmRelease`/`helm-controller`, который тянет чарт из
`HelmRepository`. Это обычный YAML-манифест, заворачивается как `Kustomization` — ровно тот же паттерн, что
и у CCM/CSI ниже, а не паттерн ingress-nginx из первой версии плана (тот был настоящим внешним чартом и
действительно ставился бы через `HelmRelease`).

Повтори по образцу для cert-manager, hcloud-ccm/csi (у них обычно готовые манифесты, заворачиваются как
`Kustomization` с source на их git/URL, тот же паттерн, что и у traefik выше), sealed-secrets.

**Важная правка после ревью — секрет `hcloud`, который создавали вручную в Этапе 3.1 для CCM, тоже нужно
перевести в GitOps.** Если оставить его только как ручной `kubectl create secret` — при полной пересборке
кластера (авария, тестовый прогон на новом проекте, что угодно) Flux развернёт всё остальное из git, а этот
секрет придётся вспоминать и создавать руками отдельно, никакого способа проверить "весь ли кластер
воспроизведён из git" не будет. Заверни его в SealedSecret так же, как секреты приложений в Этапе 4:
```bash
kubectl create secret generic hcloud \
  --namespace kube-system \
  --from-literal=token='реальный HCLOUD_TOKEN' \
  --dry-run=client -o yaml > /tmp/hcloud-secret.yaml

kubeseal --format yaml < /tmp/hcloud-secret.yaml > clusters/prod/infrastructure/hcloud-ccm/secret.sealed.yaml
rm /tmp/hcloud-secret.yaml
```
И добавь `secret.sealed.yaml` в `resources:` соответствующего `kustomization.yaml` в
`clusters/prod/infrastructure/hcloud-ccm/`, рядом с `HelmRelease`/манифестом самого CCM.

С этого момента: ручной `kubectl apply` — только для bootstrap-компонентов (Этапы 3, разово). Всё, что
касается приложений, кладётся в `clusters/prod/apps/*` и коммитится в git — Flux применяет сам.

`clusters/prod/apps/smart-rest/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: smart-rest-prod
resources:
  - namespace.yaml
  - resourcequota.yaml
  - limitrange.yaml
  - networkpolicy.yaml
  - middleware.yaml
  - deployment-web.yaml
  - deployment-queue.yaml
  - cronjobs.yaml
  - service.yaml
  - ingress.yaml
  - hpa.yaml
  - pdb.yaml
  - secrets.sealed.yaml
```
**Правка после ревью:** `limitrange.yaml` описан ниже в Этапе 6.1, но выпал из этого списка — без явного
включения в `resources:` Flux/kustomize его просто не применит, и LimitRange не заработает, несмотря на то,
что файл физически лежит в папке. Каждый файл, который должен реально применяться, обязан быть перечислен
здесь — это частая ошибка в kustomize-based GitOps: файл создан, но забыт в списке. `middleware.yaml`
(traefik `Middleware` для rate limiting, см. Этап 6.4) добавлен в список по той же причине — ровно тот же
класс ошибки, только для нового файла, а не для старого.

Как заворачивать секреты в sealed-secret (пример для DB-пароля):
```bash
kubectl create secret generic smart-rest-db \
  --namespace smart-rest-prod \
  --from-literal=DB_PASSWORD='реальный-пароль' \
  --dry-run=client -o yaml > /tmp/secret.yaml

kubeseal --format yaml < /tmp/secret.yaml > clusters/prod/apps/smart-rest/secrets.sealed.yaml
rm /tmp/secret.yaml   # НЕ коммитить незашифрованный вариант
```
`secrets.sealed.yaml` безопасно коммитить в git — расшифровать его может только контроллер в конкретном
кластере (ключ шифрования не покидает кластер).

---

## Этап 5. Внешние MariaDB / Redis / Object Storage (1 день)

### 5.1 MariaDB — отдельная VM, вне кластера

**Решение, которое стоит проговорить явно, а не оставлять незаметным побочным эффектом архитектуры.**
`db-1` ниже — одна VM, без реплики и без failover, и на неё в этом плане завязаны ВСЕ 4 прод-проекта
(smart-rest, fitness, beauty, mootq-v2) одновременно. Дальше есть протестированный backup/restore (Этап
9.4) — это правильно и обязательно, но restore — это ощутимый даунтайм (поднять VM, накатить дамп,
проверить), а не failover за секунды. Для текущего масштаба и бюджета (Приложение A) это, скорее всего,
разумный осознанный компромисс: полноценная HA-схема для MariaDB (Galera Cluster либо асинхронная
репликация primary/replica с автоматическим failover) — это минимум ещё одна-две VM того же класса
(практически удвоение стоимости DB-слоя) и заметно больше операционной сложности (split-brain,
sync/async trade-offs, сам механизм failover). Если для тебя приемлемо, что при потере `db-1` все 4 проекта
одновременно встают на время restore из бэкапа — дальше можно ничего не менять, только держи RTO из Этапа
9.4 актуальным и реально проверенным на практике. Если неприемлемо — это отдельный разговор и отдельная
доработка плана до того, как `db-1` реально ляжет, а не после.

**Важная поправка после ревью — прочитай перед тем, как полагаться на firewall-правило ниже.** Hetzner
Cloud Firewall **сейчас не фильтрует трафик внутри private networks вообще** — по официальному FAQ Hetzner
private-сеть считается "уже безопасной" и правила на неё не применяются
(https://docs.hetzner.com/cloud/firewalls/faq). Это значит: правило `source_ips = ["10.10.0.0/16"]` на
порт 3306 ниже — не даёт реальной защиты, это просто документация намерения, а не работающий контроль.

Реальная защита строится на двух вещах, и обе обязательны:
1. `bind-address = 10.10.1.100` в конфиге MariaDB (ниже) — демон физически не слушает публичный интерфейс,
   поэтому снаружи порт 3306 недоступен вообще, независимо от Hetzner Firewall.
2. Host-level firewall (`ufw`) на самой DB VM — вот он уже реально фильтрует пакеты на уровне ОС, включая
   private-интерфейс, и не полагается на Hetzner Cloud Firewall:
   ```bash
   ufw default deny incoming
   ufw allow from <твой IP>/32 to any port 22
   ufw allow from 10.10.0.0/16 to any port 3306
   ufw --force enable
   ```

Добавь в Terraform ещё один сервер (не в модуле K3s):
```hcl
resource "hcloud_server" "db_primary" {
  name        = "db-1"
  server_type = "cpx41"   # больше RAM под innodb_buffer_pool
  image       = "ubuntu-24.04"
  location    = "fsn1"
  ssh_keys    = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.db.id]   # держим как первый рубеж для публичного интерфейса, но не как единственную защиту

  network {
    network_id = hcloud_network.main.id
    ip         = "10.10.1.100"
  }
}

resource "hcloud_firewall" "db" {
  name = "db-firewall"
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.allowed_ssh_ip]
  }
  # Правило на 3306 тут НЕ добавляем вообще — раз оно не фильтрует private-трафик, а на публичном
  # интерфейсе 3306 и так закрыт implicit-deny (нет правила = нет доступа). Реальный контроль — bind-address + ufw выше.
}
```
На сервере:
```bash
apt update
apt-cache policy mariadb-server mariadb-server-10.11

if apt-cache policy mariadb-server-10.11 | grep -q "Candidate: (none)"; then
  apt install -y mariadb-server
else
  apt install -y mariadb-server-10.11
fi

mariadb --version
```
`mariadb-server-10.11` может быть доступен не во всех Ubuntu/репозиториях одинаково. Поэтому сначала
смотри `apt-cache policy`, а после установки обязательно проверяй фактическую версию через
`mariadb --version`. Если ставится метапакет `mariadb-server`, не продолжай вслепую: убедись, что это
поддерживаемая major/minor версия, совместимая с твоими приложениями и backup/restore процедурой.

`/etc/mysql/mariadb.conf.d/50-server.cnf`:
```ini
[mysqld]
bind-address = 10.10.1.100
innodb_buffer_pool_size = 10G       # ~65% от RAM CPX41 (16G) — правка после ревью, см. пояснение ниже
max_connections = 300
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
log_bin = /var/log/mysql/mariadb-bin
expire_logs_days = 7                # для point-in-time recovery через binlog
```
**Правка после ревью:** было `6G` при комментарии "60-70% от RAM сервера" — на CPX41 (16G RAM) это 37.5%, то
есть сама цифра не соответствовала собственному комментарию рядом. Поднято до `10G` (~65%), с явным запасом
~6G под ОС/page cache, соединения (300 × буферы на каждое) и `mysqldump` из Этапа 9.2 — он тоже читает через
тот же instance, и во время ночного бэкапа серверу нужна свободная память, а не только во время обычной
нагрузки. Если меняешь `server_type` под `db-1` на другой размер — пересчитай эту цифру заново под реальный
объём RAM, не копируй `10G` бездумно.
```bash
mysql_secure_installation   # обязательно: убрать anonymous users, отключить remote root
systemctl restart mariadb
ufw default deny incoming
ufw allow from <твой IP>/32 to any port 22
ufw allow from 10.10.0.0/16 to any port 3306
ufw --force enable
```
Создай отдельного пользователя и базу на проект (не root для приложения):
```sql
CREATE DATABASE smartrest CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'smartrest'@'10.10.%' IDENTIFIED BY 'сгенерированный-сложный-пароль';
GRANT ALL PRIVILEGES ON smartrest.* TO 'smartrest'@'10.10.%';
FLUSH PRIVILEGES;
```
**Проверка (обязательна именно из-за особенности private networks выше):**
```bash
# Со своего ноутбука (публичный интернет) — подключение НЕ должно установиться вообще, таймаут:
mysql -h <публичный IP db-1> -u smartrest -p
# С любой ноды кластера (внутри 10.10.0.0/16) — должно работать:
mysql -h 10.10.1.100 -u smartrest -p smartrest -e "SELECT 1;"
```
**Проверка:**
```bash
# с любой ноды кластера (внутри приватной сети):
mysql -h 10.10.1.100 -u smartrest -p smartrest -e "SELECT 1;"
# снаружи (со своего ноутбука) подключение НЕ должно работать вообще — так и должно быть
```

### 5.2 Redis
Отдельная VM тем же способом (Этап 1.5), либо `helm install` внутри кластера с `PodAntiAffinity`, если
временный даунтайм при перезапуске pod допустим для конкретного проекта. Для очередей (queue workers) —
надёжнее вынести на VM, так же закрыто firewall'ом только на `10.10.0.0/16`.

### 5.3 Object Storage
```bash
# Hetzner Console -> Object Storage -> Create bucket
# включить версионирование сразу
```
В приложении — S3-совместимый клиент (для Yii2: `aws/aws-sdk-php` с кастомным endpoint).

---

## Этап 6. Приложения: namespaces, деплой, шаблон для добавления нового проекта (2-3 дня)

### 6.1 Namespace + защитные механизмы (шаблон, повторяется на каждый проект)
```bash
kubectl create namespace smart-rest-prod
```
`resourcequota.yaml`:
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: smart-rest-quota
  namespace: smart-rest-prod
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "40"
```
`limitrange.yaml` (защита от pod без лимитов вообще — забытый `resources:` блок может занять всю ноду):
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: smart-rest-limits
  namespace: smart-rest-prod
spec:
  limits:
    - type: Container
      default: {cpu: 500m, memory: 512Mi}
      defaultRequest: {cpu: 100m, memory: 128Mi}
```

### 6.2 Deployment (web) с HPA и PodDisruptionBudget

**Проверка перед тем, как полагаться на HPA:** K3s включает metrics-server по умолчанию, отдельно ставить
не нужно — но убедись, что он реально отдаёт данные, иначе HPA будет тихо "висеть" на `minReplicas`, не
масштабируясь, и это можно не заметить до пиковой нагрузки:
```bash
kubectl top nodes
kubectl top pods -n smart-rest-prod
# оба должны показывать реальные цифры CPU/memory, не ошибку "metrics not available"
```
Если ошибка — проверь `kubectl -n kube-system get pods | grep metrics-server` и его логи.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smart-rest-web
  namespace: smart-rest-prod
spec:
  replicas: 4
  selector:
    matchLabels: {app: smart-rest-web}
  template:
    metadata:
      labels: {app: smart-rest-web}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: {app: smart-rest-web}
                topologyKey: kubernetes.io/hostname
      containers:
        - name: web
          image: registry.example.com/smart-rest:GIT_SHA
          resources:
            requests: {cpu: 300m, memory: 512Mi}
            limits:   {cpu: 1000m, memory: 1Gi}
          readinessProbe:
            httpGet: {path: /health, port: 80}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /health, port: 80}
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: smart-rest-web-pdb
  namespace: smart-rest-prod
spec:
  minAvailable: 2
  selector:
    matchLabels: {app: smart-rest-web}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: smart-rest-web-hpa
  namespace: smart-rest-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: smart-rest-web
  minReplicas: 4
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: 65}
```
`podAntiAffinity` — реплики web стараются размазываться по разным нодам, чтобы падение одной ноды не
снесло сразу половину реплик. `PodDisruptionBudget` защищает от того, что K8s одновременно уронит слишком
много реплик при обновлении ноды (node drain).

### 6.3 Queue workers, cron, миграции
Как в предыдущей версии плана — отдельный Deployment для очередей, `CronJob` для расписаний, отдельный
`Job` для миграций (запускается вручную/через CI approval, не автоматически при старте pod).

### 6.4 Ingress с TLS

**Правка после ревью:** rate limiting теперь не аннотациями на `Ingress` (у traefik готовых
`nginx.ingress.kubernetes.io/*`-аналогов на голом `Ingress` нет), а отдельным CRD `Middleware` плюс ссылка
на него аннотацией. `average`/`burst` — токен-бакет (запросы в секунду в среднем / всплеск), не прямой
аналог nginx-овского отдельного `limit-connections` (лимит одновременных соединений) — но для той же цели
защиты от резкого всплеска трафика на один сервис этого достаточно.
```yaml
# clusters/prod/apps/smart-rest/middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: smart-rest-ratelimit
  namespace: smart-rest-prod
spec:
  rateLimit:
    average: 20
    burst: 50
```
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smart-rest-web
  namespace: smart-rest-prod
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.middlewares: smart-rest-prod-smart-rest-ratelimit@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts: [smartrest.example.com]
      secretName: smart-rest-tls
  rules:
    - host: smartrest.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: smart-rest-web, port: {number: 80}}
```
Формат значения в `router.middlewares` — `<namespace>-<имя Middleware>@kubernetescrd`, не просто имя.
Для fitness/beauty/mootq (Этап 6.5) — свой `middleware.yaml` с тем же именем-паттерном и своим namespace в
аннотации, не общий на все проекты, иначе резкий всплеск трафика на один сайт съест лимит и у остальных.

### 6.5 Шаблон "как добавить новый проект" (fitness — как пример, применимо к любому будущему)
1. `mkdir clusters/prod/apps/fitness`
2. Скопировать файлы из `smart-rest/` как шаблон, заменить имена/namespace/домен/образ.
3. Своя `resourcequota.yaml` — размер зависит от ожидаемой нагрузки (см. Приложение B — расчёт capacity).
4. Своя схема/пользователь в MariaDB (`CREATE DATABASE fitness...`, отдельный юзер, НЕ шарить пароль
   между проектами).
5. Свой `secrets.sealed.yaml` через `kubeseal`.
6. Свой `deployment-fitness-migrate` Job для первого запуска миграций.
7. Commit + push в `hetzner-prod-infra` — Flux применит сам за 1-5 минут (или мгновенно, если настроен
   webhook GitHub -> Flux).
8. Перед тем как переключать реальный DNS на прод-домен — проверить через `curl --resolve
   fitness.example.com:443:<LB_IP> https://fitness.example.com/health`, не трогая DNS вообще.
9. Только после успешной проверки — добавить/поменять DNS A-запись.
10. Если после добавления `kubectl top nodes` показывает нехватку ресурсов — вернуться в Terraform,
    увеличить `worker_count`, `terraform apply` (см. Этап 1.8, процедура та же).

---

## Этап 7. CI/CD (1 день)

Пример на GitHub Actions (репозиторий приложения smart-rest):
```yaml
name: deploy-prod
on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: composer install --no-dev
      - run: composer validate
      - run: vendor/bin/phpunit   # реальный тестовый прогон проекта — замени на то, что у тебя есть на самом деле

  build:
    needs: test
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t registry.example.com/smart-rest:${{ github.sha }} .
      - run: docker push registry.example.com/smart-rest:${{ github.sha }}
      - name: setup kustomize
        uses: imranismail/setup-kustomize@v2
      - name: update image tag in GitOps repo
        run: |
          git clone https://x-access-token:${{ secrets.GITOPS_TOKEN }}@github.com/your-org/hetzner-prod-infra
          cd hetzner-prod-infra
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          cd clusters/prod/apps/smart-rest
          kustomize edit set image registry.example.com/smart-rest:${{ github.sha }}
          cd ../../../..
          git commit -am "deploy smart-rest: ${{ github.sha }}"
          git push
```
**Правка после второго раунда ревью — до этого пайплайн ехал в прод вообще без страховки.** Раньше между
`push` в `main` и реальным деплоем в общий на 4 проекта кластер стояла только `composer validate` — а это
проверка консистентности `composer.json`/`composer.lock`, не логики приложения; по сути пайплайн проезжал
в прод без единого теста. Два изменения:
- Тесты вынесены в отдельный job `test`, `build` объявлен через `needs: test` — деплой физически не может
  начаться, пока тесты не прошли. `vendor/bin/phpunit` тут — заглушка под реальный тестовый прогон проекта;
  если тестов пока нет вообще, это отдельный и более важный пробел, чем всё остальное в этом документе.
- `environment: production` на job `build` — сам по себе в YAML он ничего не блокирует, это просто имя
  окружения. Реальный gate настраивается отдельно в GitHub: Settings -> Environments -> `production` ->
  Required reviewers. Без этой настройки в интерфейсе GitHub строчка `environment: production` не даёт
  никакой защиты, только видимость в UI, какое окружение затронуто.

**Правка после ревью:** `git commit` в GitHub Actions runner упадёт с ошибкой без настроенных
`user.name`/`user.email` — на чистом runner’е identity не задана по умолчанию. `git config` добавлен сразу
после `clone`, до первого commit.

**Остальные правки:**
- сырой `sed -i "s|image: .*|...|"` заменит ЛЮБУЮ строку с `image:` в файле — если в Deployment появится
  второй контейнер (sidecar, init-container) или несколько манифестов в одном файле, `sed` может подменить
  не тот образ. `kustomize edit set image` работает по точному имени контейнера и модифицирует только
  `kustomization.yaml`, что безопаснее и предсказуемее для GitOps.
- Вручную собранный URL вида `.../releases/latest/download/kustomize_v5.4.3_...` тоже хрупкий: смешивает
  `latest` (динамическая часть пути) с захардкоженной версией в имени файла — при выходе новой версии
  `latest` начнёт указывать на релиз, где файла с таким именем уже нет, и загрузка сломается молча до
  первого деплоя после релиза. Готовый GitHub Action (`imranismail/setup-kustomize` или официальный
  `kubernetes-sigs/kustomize` install-скрипт) решает версионирование сам и не ломается от чужих релизов.

`GITOPS_TOKEN` — отдельный fine-grained PAT с правами только на репозиторий `hetzner-prod-infra`, не общий
токен с доступом ко всему.

Каждый проект (fitness, beauty...) получает свой такой workflow в своём репозитории, обновляющий свой путь
внутри `hetzner-prod-infra`.

---

## Этап 8. Мониторинг, логи, алерты (1 день)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword='сложный-пароль-сюда'

# loki-stack ниже — устоявшийся вариант на момент написания плана, но у Grafana Loki периодически меняется
# рекомендуемая схема установки (например, в пользу Loki + Alloy вместо Promtail). Перед реальным apply
# зайди на https://grafana.com/docs/loki/latest/setup/install/ и сверься с текущей рекомендацией.
helm install loki grafana/loki-stack -n monitoring
```
**Проверка:**
```bash
kubectl -n monitoring get pods
# все Running, включая prometheus, grafana, alertmanager, loki, promtail
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# открыть localhost:3000, залогиниться admin/пароль
```

Не публикуй Grafana через публичный Ingress без дополнительной защиты (VPN/basic-auth/oauth2-proxy) —
это дашборд с деталями всей инфраструктуры.

Алерты, которые нужны с первого дня (не после инцидента):
- **Disk pressure на нодах** (`node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.15`) —
  приоритет №1, у тебя уже был реальный инцидент с этим на старом кластере.
- Pod restarts / CrashLoopBackOff.
- HPA упёрся в `maxReplicas` дольше 10 минут.
- MariaDB: `Threads_connected` близко к `max_connections`, рост `Slow_queries`.
- Redis: `used_memory` близко к `maxmemory`.
- Certificate expiry (cert-manager обычно продлевает сам, но алерт на "истекает через <14 дней" — страховка).
- etcd: latency, quorum health.
- Node NotReady дольше 5 минут.

Alertmanager -> Telegram/Slack (выбери, чем реально будешь пользоваться, иначе алерты будут игнорироваться).

---

## Этап 9. Бэкапы и Disaster Recovery — с реальным тестом восстановления (0.5 дня + ежеквартально)

### 9.1 etcd snapshot (состояние самого Kubernetes — deployments, secrets, configmaps и т.д.)
K3s с embedded etcd делает snapshot автоматически каждые 12 часов по умолчанию, хранит 5 последних.
Проверь и настрой explicit:
```bash
# на любой control-plane ноде, добавить в systemd unit k3s или флаги при старте:
# --etcd-snapshot-schedule-cron="0 */6 * * *"
# --etcd-snapshot-retention=10
# --etcd-s3 (если хочешь сразу класть snapshot в Object Storage, а не только локально на ноде)
k3s etcd-snapshot save --name manual-test-$(date +%F)
k3s etcd-snapshot ls
```
Настрой выгрузку snapshot в Object Storage (`--etcd-s3 --etcd-s3-bucket=... --etcd-s3-endpoint=...`) —
если сгорят все 3 control-plane ноды одновременно (маловероятно, но именно для этого HA snapshot нужен
не только локально).

### 9.2 MariaDB
```bash
# на db-1, через cron ежедневно:
mysqldump --all-databases --single-transaction | gzip > /backups/db-$(date +%F).sql.gz
# закачка в Object Storage (rclone или aws-cli с кастомным endpoint)
rclone copy /backups/db-$(date +%F).sql.gz hetzner-s3:backups/mariadb/
# бинлоги (уже включены в 5.1) дают point-in-time recovery между полными дампами
```
Ротация: хранить полные дампы минимум 14 дней, бинлоги — минимум 7 дней сверх последнего дампа.

`mysqldump` нормально стартовать с этого — он логический дамп, простой и надёжный для небольших/средних
БД. Когда база вырастет настолько, что `mysqldump`+restore начнёт занимать часы (обычно это заметно уже
на 20-50GB), переходи на `mariabackup`/`xtrabackup` — физический бэкап, восстанавливается на порядок
быстрее и не блокирует таблицы так долго. Не обязательно делать это сразу, но держи в голове как следующий
шаг, а не как то, что можно откладывать бесконечно.

### 9.3 Object Storage
Версионирование бакета включено в консоли (Этап 5.3) — защищает от случайного перезаписывания/удаления
файла приложением.

### 9.4 РЕАЛЬНЫЙ тест восстановления — обязательно, не пропускать
Бэкап, который ни разу не восстанавливали — это не бэкап, это файл, в котором ты не уверен. Сделай **один
раз сразу после Этапа 9**, и затем раз в квартал:

1. Подними отдельный тестовый сервер (не прод!) через тот же Terraform-модуль с другим именем.
2. Восстанови туда последний `mysqldump`:
   ```bash
   gunzip < db-2026-07-01.sql.gz | mysql -h <тестовый сервер>
   ```
3. Проверь, что данные реально читаются, счётчики строк совпадают с ожиданием.
4. Для etcd — тестовое восстановление snapshot на отдельном тестовом K3s control-plane:
   ```bash
   k3s server --cluster-reset --cluster-reset-restore-path=<путь-к-snapshot>
   ```
   (делать только на тестовом кластере, никогда не экспериментировать с этой командой на проде).
5. Запиши время, которое ушло на восстановление — это твой реальный RTO (Recovery Time Objective),
   а не теоретический.

---

## Приложение A. Грубая оценка стоимости (Hetzner, ориентир на момент написания)

| Ресурс | Тип | Кол-во | Прим. цена/мес (EUR) |
|---|---|---|---|
| Control-plane | CPX31 | 3 | ~13 x 3 = 39 |
| Workers | CPX41 | 4 | ~24 x 4 = 96 |
| DB VM | CPX41 | 1 | ~24 |
| Load Balancer | LB11 | 1 | ~6 |
| Object Storage | ~100-500GB | 1 | ~5-25 |
| Traffic | обычно включён в разумных пределах | — | — |

Итого ориентировочно **170-200 EUR/мес** для старта на 4 проекта. Уточни актуальные цены в Hetzner
Console перед запуском — они могли измениться.

---

## Приложение B. Как понять, сколько ресурсов закладывать в ResourceQuota нового проекта

1. Если проект уже работает на старом кластере — посмотри его реальное потребление там:
   ```bash
   kubectl top pods -n <старый-namespace-если-есть> --sort-by=cpu
   ```
2. Если нового проекта ещё нет в проде — заложи по умолчанию: `requests.cpu: 1`, `requests.memory: 2Gi`
   на старте, с HPA `minReplicas: 2, maxReplicas: 8`, и пересмотри квоту через неделю по факту
   `kubectl top`.
3. Общее правило: сумма `requests` (не `limits`) всех namespace не должна превышать ~70% суммарной
   ёмкости кластера — оставляй запас на всплески и на возможность передвинуть pod при node drain.
4. `kubectl describe nodes | grep -A5 "Allocated resources"` — смотреть по каждой ноде, не только
   суммарно.

---

## Приложение C. Security hardening — короткий чек-лист

- [ ] SSH только по ключу, `PasswordAuthentication no` в `/etc/ssh/sshd_config` на всех нодах.
- [ ] `fail2ban` на всех нодах для SSH.
- [ ] Автоматические security-обновления Ubuntu: `unattended-upgrades`.
- [ ] k3s token, hcloud token, db-пароли — только в секрет-хранилище, ротация раз в 3-6 месяцев.
- [ ] `kubectl` доступ снаружи — только через SSH-туннель/VPN, не публичный 6443 (уже заложено в Этапе 1.4/2.6).
- [ ] RBAC: не давать `cluster-admin` никому кроме себя лично; для CI/CD — отдельный ServiceAccount с
      правами только на нужные namespace.
- [ ] `NetworkPolicy` default-deny в каждом namespace (Этап 3.6).
- [ ] Секреты приложений — только через sealed-secrets, никогда plain `Secret` в git.
- [ ] Регулярно (раз в квартал) — `kubectl get clusterrolebinding` ревизия, кто на что имеет доступ.

---

## Приложение D. Частые ошибки первого прод-кластера (чтобы не наступить)

- **Нечётное число control-plane нод забыто** — поставили 2 или 4, etcd quorum ломается некрасиво при
  потере одной ноды. Всегда 3 или 5.
- **DB на PVC внутри кластера** — Hetzner Volume не HA, при потере ноды с volume — простой до ручного
  восстановления. MariaDB/Redis критичных данных — только вне кластера.
- **Секреты в открытом виде в git** — даже "временно, потом уберу" — история git всё помнит.
- **Нет readiness/liveness probe** — K8s не понимает, что pod реально готов принимать трафик, роняет
  запросы во время деплоя.
- **Нет ResourceQuota/LimitRange** — один проект с багом (memory leak) может забрать всю ноду и уронить
  соседние проекты.
- **Firewall на 0.0.0.0/0 для SSH "чтобы не мучиться"** — первое, что просканируют боты в интернете.
- **Бэкапы есть, но никогда не тестировался restore** — узнаёшь, что бэкап битый, в момент, когда он
  реально нужен.
- **DNS TTL не снижен заранее** перед любым будущим переключением (даже если сейчас миграции нет, привычка
  пригодится) — переключение занимает часы вместо минут.
- **Один и тот же SSH-ключ/токен на старом и новом кластере** — компрометация одного окружения даёт доступ
  ко второму.

---

## Итоговый чек-лист выполнения

- [ ] Этап -1: пре-флайт чек-лист пройден полностью
- [ ] Этап 0: инструменты, .gitignore (lock-файл Terraform НЕ игнорируется), структура репо `hetzner-prod-infra`
- [ ] Этап 1: Terraform apply — сеть, раздельные firewall (control-plane: только SSH; workers: только SSH, 80/443 закрыты — вход только через LB по private IP), `pathexpand()` для SSH-ключа, `k3s_version` вынесен в переменную и прокинут во все три `templatefile()`, LB target с `use_private_ip = true` и явным `depends_on`, 3 CP + N worker — `terraform output` проверен
- [ ] Этап 2.0: имя приватного интерфейса проверено ЗАРАНЕЕ на тестовой одноразовой VM (не вслепую `enp7s0`, не постфактум после боевого apply)
- [ ] Этап 2: K3s HA bootstrap с версией из `var.k3s_version`, актуальной на момент apply (проверена на kubernetes.io/releases и k3s-io/k3s/releases, не взята бездумно из этого документа), control-plane тейнтом, control-plane БЕЗ host-level 80/443, `--disable-cloud-controller`+`cloud-provider=external` на всех нодах, `container-log-max-size`/`container-log-max-files` заданы явно (Этап 2.1 — урок со smp), `--advertise-address` рядом с `--node-ip`, `--tls-san` покрывает все три приватных IP control-plane (не только cp-1) + fallback SSH-туннели на cp-2/cp-3 настроены (Этап 2.5), приватный IP из Terraform (не `hostname -I`), default kubeconfig mode (600), traefik НЕ отключён (`--disable traefik` убран) — `kubectl get nodes` все Ready через SSH-туннель, etcd healthy проверен корректной для K3s командой
- [ ] Этап 3: CCM и CSI — версии получены динамически на момент apply (НЕ версии ≤v1.30.0 у CCM — официально ломаются после изменений в Hetzner API), базовый `ccm.yaml` (не networks-режим), traefik донастроен через `HelmChartConfig` (hostNetwork + DaemonSet + `nodeSelector` на worker-label + порты 80/443, НЕ ingress-nginx — retired с марта 2026, источник в Этапе 3.3), проверено не только по статусу пода, но и что pod'ы Traefik не стоят на `cp-*`, `ss -lntp` на ноде + `curl --resolve` сквозь LB, cert-manager (staging -> prod issuer, класс `traefik`), sealed-secrets установлен по pinned release tag (не `latest`), NetworkPolicy (default-deny + DNS egress + явные разрешения, ingress-правило смотрит на `kube-system`+label traefik, не на несуществующий namespace `ingress-nginx`)
- [ ] Этап 4: Flux bootstrap, `flux check` зелёный, bootstrap-компоненты Этапа 3 переведены в HelmRelease/Kustomization (traefik — именно Kustomization поверх HelmChartConfig, не HelmRelease), `hcloud` secret тоже заведён как SealedSecret (не только ручной kubectl create)
- [ ] Этап 5: MariaDB VM (пакет/версия проверены через `apt-cache policy` + `mariadb --version`, bind-address на приватный IP + ufw хост-firewall, Hetzner Cloud Firewall НЕ полагаемся для private network), отсутствие DB HA — осознанный и явно проговорённый компромисс (не молчаливый пробел), `innodb_buffer_pool_size` реально соответствует заявленным 60-70% RAM инстанса, Redis, Object Storage с версионированием
- [ ] Этап 6: namespace + quota + `limitrange.yaml` и `middleware.yaml` (оба явно включены в kustomization resources) + PDB для smart-rest, Ingress использует `ingressClassName: traefik`, `kubectl top nodes` подтверждает metrics-server работает, шаблон готов для будущих проектов
- [ ] Этап 7: CI/CD pipeline через `kustomize edit set image` (не sed) и готовый GitHub Action (не hand-crafted URL), `git config user.name/user.email` перед commit, отдельный GITOPS_TOKEN, есть шаг с тестами перед build/push и ручной approval (GitHub environment protection) перед деплоем в общий на 4 проекта прод
- [ ] Этап 8: Prometheus/Grafana/Loki, алерты (disk pressure — приоритет), Alertmanager -> реальный канал
- [ ] Этап 9: бэкапы настроены + ОДИН раз проведён реальный тест восстановления
- [ ] Приложение C: security-чек-лист пройден

**Помни про threat model приватной сети (Этап 1.4):** `ufw allow from 10.10.0.0/16` открывает все порты
между нодами внутри приватной сети ради простоты — SSH-туннель защищает доступ к API снаружи, но не
абсолютно изолирует 6443 от других нод внутри той же сети. Это осознанный компромисс для старта, не забытая
дыра — но именно поэтому важно, чтобы в этой приватной сети не оказалось ничего лишнего.

Оценка: 8-11 рабочих дней при вдумчивом прохождении с проверками. Не сжимай это время искусственно —
на первом проде лучше на 2 дня дольше, чем потом разбирать инцидент в 3 часа ночи.
