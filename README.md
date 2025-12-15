# vff-qos
![License](https://img.shields.io/badge/license-MIT-2AAEE8?style=flat-square)
![Linux](https://img.shields.io/badge/platform-Linux-2AAEE8?style=flat-square)
![Ansible](https://img.shields.io/badge/automation-Ansible-6F42C1?style=flat-square)
![systemd](https://img.shields.io/badge/runtime-systemd-6F42C1?style=flat-square)
![QoS](https://img.shields.io/badge/qos-tc%2Fifb%20HTB-2AAEE8?style=flat-square)
![Xray](https://img.shields.io/badge/xray-supported-6F42C1?style=flat-square)

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

## ♻️ QoS Garbage Collection (tc GC) — TL;DR

В системе per-user QoS со временем накапливаются устаревшие **HTB-классы и fw-фильтры**
(например, после отключения пользователей). Для предотвращения деградации `tc`
используется отдельный механизм **QoS Garbage Collection**.

**Кратко:**
- периодически удаляет неиспользуемые per-user HTB классы (`1:<mark>`, `2:<mark>`);
- чистит связанные fw-фильтры на WAN и IFB;
- автоматически удаляет «висячие» фильтры (filter есть — class отсутствует);
- **никогда не затрагивает активных пользователей**.

**Класс удаляется, если:**
- существует дольше `QOS_GC_MIN_AGE_SEC` (защитный интервал после создания класса);
- нет трафика дольше `QOS_GC_IDLE_SEC` (по умолчанию 4 часа);
- *(опционально)* нет активных conntrack-сессий с этим mark.

GC запускается через `systemd timer`, работает как `oneshot` и
**не находится в follower-loop**, поэтому не влияет на обработку трафика.

📘 Подробное описание алгоритма и параметров —  
[`docs/QOS_GC.md`](docs/QOS_GC.md)

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

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [QoS Garbage Collection (tc GC)](docs/QOS_GC.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

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
    QOS_GC.md
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

### Полностью удалить QoS

Останавливает сервисы, удаляет systemd-юниты, nftables include и tc/ifb.

```bash
make qos-absent
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

## 🧭 Место в экосистеме VFF

`vff-qos` — отдельный сетевой инфраструктурный слой, независимый от панели управления.
Он может использоваться вместе с Remnawave, Marzban или любым другим Xray-стеком.

---

## 🤝 Поддержка и вклад

Pull request’ы приветствуются:
- улучшения Ansible-ролей;
- доработки GC, tc/nft логики;
- улучшения и расширение документации.

По возможности сопровождайте изменения:
- кратким описанием мотивации;
- примерами проверки или валидации (dry-run, команды, скриншоты).

Проект развивается как **production-first infrastructure**, поэтому приоритет —
предсказуемость, идемпотентность и безопасность изменений.

---

## 🤝 Автор

**Sergey Ryabkov**  
GitHub: [@ryabkov82](https://github.com/ryabkov82)
Проект: [VPN for Friends](https://t.me/vpn_for_myfriends_bot)

---

## 📄 Лицензия

MIT
