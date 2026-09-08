# ============================================================================
# Короткие команды поверх scripts/*.sh. CI вызывает те же скрипты, поэтому
# `make` локально и пайплайн делают ровно одно и то же.
# ============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

PLATFORM ?= x86_64-cuda
PACKAGE  ?= fast_lio2
MODE     ?= native
REGISTRY ?= ghcr.io
IMAGE_OWNER ?= $(shell git config --get remote.origin.url 2>/dev/null | sed -E 's#.*[:/]([^/]+)/[^/]+$$#\1#' | tr 'A-Z' 'a-z')
export REGISTRY IMAGE_OWNER

PLATFORMS := $(patsubst platforms/%.env,%,$(wildcard platforms/*.env))
PACKAGES  := $(filter-out _template,$(patsubst packages/%.env,%,$(wildcard packages/*.env)))

.PHONY: help
help:  ## Показать эту справку
	@echo "Платформы: $(PLATFORMS)"
	@echo "Пакеты:    $(PACKAGES)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Примеры:"
	@echo "  make base PLATFORM=jetson-agx-orin-jp62"
	@echo "  make package PACKAGE=fast_lio2 PLATFORM=jetson-orin-nano-jp7 MODE=cross"
	@echo "  make verify PACKAGE=fast_lio2 PLATFORM=x86_64-cuda"

.PHONY: qemu
qemu:  ## Зарегистрировать QEMU binfmt для кросс-сборки arm64
	./scripts/setup-qemu.sh

.PHONY: base
base:  ## Собрать базовый образ одной платформы (PLATFORM=...)
	./scripts/build-base.sh --platform $(PLATFORM)

.PHONY: base-all
base-all:  ## Собрать базовые образы всех платформ
	./scripts/build-base.sh --all

.PHONY: base-push
base-push:  ## Собрать и запушить базовый образ (PLATFORM=...)
	./scripts/build-base.sh --platform $(PLATFORM) --push --no-load

.PHONY: package
package:  ## Собрать образ пакета (PACKAGE=... PLATFORM=... MODE=native|cross)
	./scripts/build-package.sh --package $(PACKAGE) --platform $(PLATFORM) --mode $(MODE)

.PHONY: package-push
package-push:  ## Собрать и запушить образ пакета
	./scripts/build-package.sh --package $(PACKAGE) --platform $(PLATFORM) --mode $(MODE) --push --no-load

.PHONY: verify
verify:  ## Проверить собранный образ пакета
	./scripts/verify-image.sh \
		--image $(REGISTRY)/$(IMAGE_OWNER)/$(PACKAGE):$(PLATFORM)-$(MODE) \
		--platform $(PLATFORM) --package $(PACKAGE) \
		--report verify-$(PLATFORM)-$(MODE).md

.PHONY: verify-base
verify-base:  ## Проверить базовый образ
	./scripts/verify-image.sh \
		--image $(REGISTRY)/$(IMAGE_OWNER)/ros2-cuda-base:$(PLATFORM) \
		--platform $(PLATFORM) --report verify-base-$(PLATFORM).md

.PHONY: shell
shell:  ## Интерактивная оболочка внутри образа пакета
	docker run --rm -it \
		--platform $$(grep -oP 'DOCKER_PLATFORM="\K[^"]+' platforms/$(PLATFORM).env) \
		$$([ -e /dev/nvidiactl ] && echo --gpus all) \
		$(REGISTRY)/$(IMAGE_OWNER)/$(PACKAGE):$(PLATFORM)-$(MODE) bash

.PHONY: lint
lint:  ## Проверить синтаксис скриптов и Dockerfile
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh scripts/lib/*.sh packages/prebuild/*.sh || echo "shellcheck не установлен, пропуск"
	@for f in docker/base/* docker/package/Dockerfile; do \
		[ -f "$$f" ] && docker run --rm -i hadolint/hadolint < "$$f" || true; \
	done

.PHONY: clean
clean:  ## Удалить локальные образы проекта и кеш buildx
	-docker images --format '{{.Repository}}:{{.Tag}}' \
		| grep -E "$(IMAGE_OWNER)/(ros2-cuda-base|$(shell echo $(PACKAGES) | tr ' ' '|'))" \
		| xargs -r docker rmi -f
	-docker buildx prune -f
