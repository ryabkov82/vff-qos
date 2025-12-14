# vff-qos

Infrastructure-level **per-user traffic shaping (QoS)** for VPN/Xray nodes.  
Designed as an independent, reusable component of the **VPN for Friends (VFF)** ecosystem.

Проект реализует **per-user лимиты скорости** на уровне ядра Linux с использованием:
- `conntrack mark` (на основе Xray access log),
- `nftables` (перенос `ct mark → skb mark`),
- `tc + ifb` (HTB shaping для upload и download),
- `systemd` сервисов для bootstrap и runtime-обработки.

QoS **не привязан логически к Remnawave** и может использоваться с любым Xray-совместимым стеком,
где доступен access log с идентификатором пользователя (email / username).

---

## ✨ Возможности

- Per-user лимиты скорости (upload / download)
- Источник истины — **Xray access log**
- Идентификация пользователя по `email`
- Kernel-level shaping (tc/ifb), без proxy-level throttling
- Авто-определение WAN интерфейса (`default route`)
- Idempotent конфигурация (без разрушительных reset’ов)
- Управляемые состояния:
  - `present` — включено
  - `disabled` — быстрый kill-switch
  - `absent` — полный демонтаж
- Поддержка include-модели `nftables`
- Подходит для продакшена и нагрузочного профиля (speedtest, sustained traffic)

---

## 🧠 Архитектура (коротко)

```
Xray access log (email + src ip:port)
        |
        v
qos_follow_xray_email.sh
  - вычисляет mark(email)
  - conntrack -U (tcp flow)
        |
        v
conntrack mark
        |
        v
nftables (ct mark → skb mark)
        |
        v
tc fw classifier
        |
        +--> IFB (upload shaping)
        |
        +--> WAN egress (download shaping)
```

Ключевой момент: **`action ctinfo cpmark`** на ingress — гарантирует,
что skb mark соответствует conntrack mark для всего lifetime TCP-сессии.

📘 **Подробнее об архитектуре и потоках данных** см. в  
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## 📦 Состав репозитория

```
vff-qos/
  ansible/
    roles/
      qos_per_user_xray/
  tools/
    qos_cpu_capture.sh
  docs/
    ARCHITECTURE.md
    TROUBLESHOOTING.md
  README.md
```

---

## 🚀 Использование

### Как standalone Ansible-роль

```yaml
- hosts: vpn_nodes
  become: true
  roles:
    - role: qos_per_user_xray
      vars:
        qos_state: present
```

### Как dependency в другом проекте

```yaml
roles:
  - name: qos_per_user_xray
    src: git@github.com:ryabkov82/vff-qos.git
    scm: git
    version: v0.1.0
```

---

## ⚡ Quick start (Makefile)

Для оперативного управления QoS в репозитории предусмотрен `Makefile`.
Все команды выполняются **из корня репозитория `vff-qos`**.

### Включить / установить QoS на всех нодах

```bash
make qos
```

### Включить QoS на одной ноде

```bash
make qos LIMIT=nl-ams-1
```

### Быстро отключить QoS (kill switch)

Останавливает QoS-сервисы, **не удаляя** конфигурацию и правила tc/nft.

```bash
make qos-disable
```

На одной ноде:

```bash
make qos-disable LIMIT=de-fra-1
```

### Полностью удалить QoS

Останавливает сервисы, удаляет systemd-юниты, nftables include и tc/ifb.

```bash
make qos-absent
```

На одной ноде:

```bash
make qos-absent LIMIT=fi-hel-1
```

### Передача дополнительных параметров

Любые Ansible extra-vars можно передать через `EXTRA`:

```bash
make qos LIMIT=nl-ams-1 EXTRA='-e qos_upload_default=300mbit -e qos_download_default=500mbit'
```

### Проверки и линтинг

```bash
make lint      # ansible-lint
make syntax    # ansible-playbook --syntax-check
```

---

## ⚙️ Основные переменные

```yaml
qos_state: present        # present | disabled | absent
qos_if_wan: auto
qos_if_ifb: ifb0

qos_container: remnanode
qos_xray_access_log_path: /var/log/supervisor/xray.out.log
qos_vpn_port: "443"

qos_upload_default: 1000mbit
qos_download_default: 1000mbit
```

---

## 🔀 Управление состоянием

- **present** — установить и включить QoS  
- **disabled** — остановить QoS (быстрый и безопасный откат)  
- **absent** — полностью удалить и откатить tc/nft  

---

## 📊 Замеры нагрузки

В `tools/qos_cpu_capture.sh` — утилита для оценки CPU overhead под нагрузкой
(speedtest / sustained traffic).

---

## 🧭 Место в экосистеме VFF

`vff-qos` — отдельный сетевой инфраструктурный слой, независимый от панели управления.
Он может использоваться вместе с Remnawave, Marzban или любым другим Xray-стеком.

---

## 📄 Лицензия

MIT
