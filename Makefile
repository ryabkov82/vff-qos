# =========================
# vff-qos Makefile
# =========================
#
# Примеры запуска:
#
#   make qos
#   make qos LIMIT=nl-ams-1
#   make qos EXTRA='-e qos_upload_default=500mbit'
#
#   make qos-disable
#   make qos-disable LIMIT=de-fra-1
#
#   make qos-absent
#   make qos-absent LIMIT=fi-hel-1
#
#   make lint
#   make syntax
#

ANSIBLE_DIR        ?= ansible
PLAYBOOK           ?= $(ANSIBLE_DIR)/playbooks/qos.yml
INVENTORY          ?= $(ANSIBLE_DIR)/inventory/hosts.ini
ANSIBLE_CFG        ?= $(ANSIBLE_DIR)/ansible.cfg

ANSIBLE_PLAYBOOK   ?= ansible-playbook
EXTRA              ?=
LIMIT              ?=

ENV = \
	ANSIBLE_CONFIG=$(ANSIBLE_CFG)

COMMON_ARGS = \
	-i $(INVENTORY) \
	$(if $(LIMIT),--limit $(LIMIT),) \
	$(EXTRA)

# -------------------------
# Help
# -------------------------
# Показать краткую справку по доступным целям
#
# Пример:
#   make help
#
.PHONY: help
help:
	@echo ""
	@echo "vff-qos targets:"
	@echo ""
	@echo "  make qos                 - deploy/enable QoS on all nodes"
	@echo "  make qos-disable         - disable QoS (kill switch)"
	@echo "  make qos-absent          - fully remove QoS"
	@echo ""
	@echo "Node selection:"
	@echo "  make qos LIMIT=nl-ams-1"
	@echo "  make qos-disable LIMIT=de-fra-1"
	@echo ""
	@echo "Extra vars:"
	@echo "  make qos EXTRA='-e qos_upload_default=500mbit'"
	@echo ""

# -------------------------
# Main targets
# -------------------------

# Включить / установить QoS на всех нодах
#
# Примеры:
#   make qos
#   make qos LIMIT=nl-ams-1
#   make qos EXTRA='-e qos_upload_default=300mbit -e qos_download_default=500mbit'
#
.PHONY: qos
qos:
	$(ENV) $(ANSIBLE_PLAYBOOK) $(PLAYBOOK) $(COMMON_ARGS) -e qos_state=present

# Быстро отключить QoS (kill switch, без удаления конфигурации)
#
# Примеры:
#   make qos-disable
#   make qos-disable LIMIT=de-fra-1
#
.PHONY: qos-disable
qos-disable:
	$(ENV) $(ANSIBLE_PLAYBOOK) $(PLAYBOOK) $(COMMON_ARGS) -e qos_state=disabled

# Полностью удалить QoS (systemd, tc, nft, файлы)
#
# Примеры:
#   make qos-absent
#   make qos-absent LIMIT=fi-hel-1
#
.PHONY: qos-absent
qos-absent:
	$(ENV) $(ANSIBLE_PLAYBOOK) $(PLAYBOOK) $(COMMON_ARGS) -e qos_state=absent

# -------------------------
# Convenience shortcuts
# -------------------------

# Включить QoS на одной ноде (обёртка над make qos)
#
# Пример:
#   make qos-node LIMIT=nl-ams-1
#
.PHONY: qos-node
qos-node:
	@if [ -z "$(LIMIT)" ]; then \
		echo "ERROR: specify LIMIT=<hostname>"; \
		exit 1; \
	fi
	$(MAKE) qos LIMIT=$(LIMIT)

# Отключить QoS на одной ноде
#
# Пример:
#   make qos-disable-node LIMIT=de-fra-1
#
.PHONY: qos-disable-node
qos-disable-node:
	@if [ -z "$(LIMIT)" ]; then \
		echo "ERROR: specify LIMIT=<hostname>"; \
		exit 1; \
	fi
	$(MAKE) qos-disable LIMIT=$(LIMIT)

# Полностью удалить QoS на одной ноде
#
# Пример:
#   make qos-absent-node LIMIT=fi-hel-1
#
.PHONY: qos-absent-node
qos-absent-node:
	@if [ -z "$(LIMIT)" ]; then \
		echo "ERROR: specify LIMIT=<hostname>"; \
		exit 1; \
	fi
	$(MAKE) qos-absent LIMIT=$(LIMIT)

# -------------------------
# Lint / sanity checks
# -------------------------

# Запустить ansible-lint (из директории ansible/)
#
# Пример:
#   make lint
#
.PHONY: lint
lint:
	cd $(ANSIBLE_DIR) && ansible-lint

# Проверить синтаксис playbook без выполнения
#
# Пример:
#   make syntax
#
.PHONY: syntax
syntax:
	$(ENV) $(ANSIBLE_PLAYBOOK) $(PLAYBOOK) -i $(INVENTORY) --syntax-check
