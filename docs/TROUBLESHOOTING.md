# Troublesbleshooting / Устранение неполадок

Данный документ содержит типовые проблемы, шаги диагностики и
эксплуатационные заметки для проекта **vff-qos**.

Документ намеренно минимален и предполагается к постепенному
расширению на основе реальных инцидентов в продакшене.

---

## Общая диагностика

### Проверка systemd-юнитов

```bash
systemctl status qos-follow.service
systemctl status qos-bootstrap.service
systemctl status qos-gc.timer
```

### Просмотр последних логов

```bash
journalctl -u qos-follow.service -n 200
journalctl -u qos-bootstrap.service -n 200
journalctl -u qos-gc.service -n 200
```

---

## QoS не применяется / отсутствует ограничение скорости

### Симптомы

- Трафик не ограничивается
- Speedtest показывает максимальную скорость канала
- Per-user лимиты игнорируются

### Проверки

```bash
tc qdisc show
tc class show dev eth0
tc class show dev ifb0
```

Убедитесь, что:

- HTB qdisc присутствует на WAN и IFB интерфейсах
- Создаются per-user классы (`1:<mark>`, `2:<mark>`)
- Присутствуют дефолтные классы (`1:fffe`, `2:fffe`)

---

## Per-user классы не создаются

### Симптомы

- Присутствуют только дефолтные классы
- Классы вида `1:<mark>` / `2:<mark>` не появляются после пользовательского трафика

### Проверки

- Проверьте путь к access log Xray:
```bash
ls -l /var/log/supervisor/xray.out.log
```

- Проверьте, что follower-сервис запущен:
```bash
systemctl status qos-follow.service
```

- Проверьте наличие утилиты conntrack:
```bash
which conntrack
```

- Посмотрите последние записи access log:
```bash
tail -n 50 /var/log/supervisor/xray.out.log
```

---

## GC удаляет классы неожиданно

### Симптомы

- Per-user классы исчезают, пока пользователи ещё подключены
- В логах GC видны подозрительные удаления

### Проверки

- Проверьте конфигурацию GC:
```bash
grep '^QOS_GC_' /etc/vff-qos/qos.env
```

- Запустите GC вручную в dry-run режиме:
```bash
QOS_GC_DRY_RUN=1 /usr/local/bin/qos_gc_tc.sh
```

- Рассмотрите включение защиты на основе conntrack:
```env
QOS_GC_USE_CONNTRACK=1
```

---

## Отсутствует IFB интерфейс

### Симптомы

- Ошибки, связанные с `ifb0`
- Download shaping не работает

### Проверки

```bash
ip link show ifb0
tc qdisc show dev ifb0
```

Если IFB отсутствует, попробуйте перезапустить bootstrap:

```bash
systemctl restart qos-bootstrap.service
```

---

## Заметки и best practices

- Тестируйте изменения с `QOS_GC_DRY_RUN=1`
- Избегайте агрессивных параметров GC в продакшене
- Мониторьте количество per-user классов со временем
- Рассматривайте GC как механизм безопасности, а не real-time контроллер

---

## Сообщение об ошибках

При создании issue рекомендуется приложить:

- вывод `tc qdisc show` и `tc class show`
- релевантные логи `journalctl`
- содержимое `/etc/vff-qos/qos.env`
- описание последних изменений конфигурации
