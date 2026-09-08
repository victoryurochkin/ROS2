#!/usr/bin/env bash
# ============================================================================
# Регистрация QEMU-эмуляции aarch64 через binfmt_misc.
# Нужна один раз на хосте (или на каждом запуске CI-раннера) перед
# кросс-сборкой arm64-образов на x86_64.
#
# Версия образа binfmt зафиксирована сознательно: в QEMU 7.x были ошибки
# трансляции, из-за которых nvcc и сборка PCL под aarch64 падали с
# "qemu: uncaught target signal 11 (Segmentation fault)". Начиная с
# qemu-v8.1.5 эти сборки проходят стабильно.
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BINFMT_IMAGE="${BINFMT_IMAGE:-tonistiigi/binfmt:qemu-v8.1.5}"

if [ "$(uname -m)" = "aarch64" ]; then
    ok "хост уже aarch64 — QEMU не нужен"
    exit 0
fi

log "регистрирую binfmt-обработчики из ${BINFMT_IMAGE}"
docker run --privileged --rm "${BINFMT_IMAGE}" --install arm64

log "проверка регистрации"
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    grep -E 'enabled|interpreter' /proc/sys/fs/binfmt_misc/qemu-aarch64 || true
    ok "qemu-aarch64 зарегистрирован"
else
    die "binfmt-обработчик qemu-aarch64 не появился"
fi

log "smoke-тест: запуск arm64-контейнера на x86-хосте"
docker run --rm --platform linux/arm64 arm64v8/ubuntu:22.04 uname -m
ok "QEMU готов к кросс-сборке"
