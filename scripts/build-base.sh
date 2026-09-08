#!/usr/bin/env bash
# ============================================================================
# Сборка базового образа для одной платформы.
#
#   ./scripts/build-base.sh --platform jetson-agx-orin-jp62
#   ./scripts/build-base.sh --platform jetson-orin-nano-jp7 --push
#   ./scripts/build-base.sh --all
#
# Скрипт — единая точка входа и для человека, и для CI: workflow вызывает
# ровно эту команду, поэтому локальная сборка воспроизводит CI один в один.
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PLATFORM=""
PUSH=false
LOAD=true
ALL=false
NO_CACHE=false
EXTRA_TAG=""

usage() {
    cat <<EOF
Использование: $0 [опции]

  --platform <id>   платформа из platforms/*.env
                    доступны: $(list_platforms | tr '\n' ' ')
  --all             собрать все платформы подряд
  --push            запушить в реестр (\$REGISTRY, по умолчанию ghcr.io)
  --no-load         не импортировать образ в локальный docker (для CI с --push)
  --no-cache        сборка без кеша
  --tag <suffix>    дополнительный тег, например дату или SHA
  -h, --help        эта справка

Переменные окружения:
  REGISTRY          реестр (ghcr.io)
  IMAGE_OWNER       владелец образов (org/user)
  CACHE_FROM/TO     переопределение кеша buildx
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --all) ALL=true; shift ;;
        --push) PUSH=true; shift ;;
        --no-load) LOAD=false; shift ;;
        --no-cache) NO_CACHE=true; shift ;;
        --tag) EXTRA_TAG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

build_one() {
    local platform_id="$1"
    load_platform "${platform_id}"
    ensure_builder

    local image; image="$(base_image_ref "${platform_id}")"
    local cache_ref="${image}-cache"

    # Если целевая архитектура не совпадает с архитектурой хоста — сборка идёт
    # под QEMU. Эмуляция потребляет память кратно больше нативной сборки, и
    # -j$(nproc) на типовом раннере уходит в OOM. Режем параллелизм.
    local target_arch host_arch workers
    target_arch="$(printf '%s' "${DOCKER_PLATFORM}" | cut -d/ -f2)"
    case "$(uname -m)" in aarch64) host_arch=arm64 ;; *) host_arch=amd64 ;; esac
    if [ "${target_arch}" != "${host_arch}" ]; then
        workers="${PARALLEL_WORKERS:-2}"
        warn "кросс-сборка под QEMU: PARALLEL_WORKERS=${workers}"
    else
        workers="${PARALLEL_WORKERS:-$(nproc)}"
    fi

    local args=(
        buildx build
        --file "${REPO_ROOT}/${BASE_DOCKERFILE}"
        --platform "${DOCKER_PLATFORM}"
        --tag "${image}"
        --build-arg "BASE_FROM=${BASE_FROM}"
        --build-arg "ROS_DISTRO=${ROS_DISTRO}"
        --build-arg "ROS_BASE_PACKAGE=${ROS_BASE_PACKAGE}"
        --build-arg "ROS_BUILD_MODE=${ROS_BUILD_MODE}"
        --build-arg "CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}"
        --build-arg "PLATFORM_ID=${PLATFORM_ID}"
        --build-arg "PLATFORM_DESCRIPTION=${PLATFORM_DESCRIPTION}"
        --build-arg "PARALLEL_WORKERS=${workers}"
        --provenance=false
    )

    # Jetson-специфичные аргументы передаём только Jetson-платформам.
    if [ "${PLATFORM_KIND}" = "jetson" ]; then
        args+=(
            --build-arg "L4T_SUITE=${L4T_SUITE}"
            --build-arg "L4T_SOC=${L4T_SOC}"
            --build-arg "L4T_RELEASE_MAJOR=${L4T_RELEASE_MAJOR}"
            --build-arg "L4T_RELEASE_MINOR=${L4T_RELEASE_MINOR}"
            --build-arg "JETSON_CUDA_PACKAGES=${JETSON_CUDA_PACKAGES}"
            --build-arg "CUDA_HOME=${CUDA_HOME}"
        )
    fi

    [ -n "${EXTRA_TAG}" ] && args+=(--tag "${image}-${EXTRA_TAG}")

    if [ "${NO_CACHE}" = true ]; then
        args+=(--no-cache)
    else
        # Кеш слоёв держим в самом реестре: между запусками CI на разных
        # раннерах локального кеша не существует, а registry-кеш переживает
        # всё. mode=max сохраняет и промежуточные слои (важно: apt-слои
        # ставят по 2-4 ГБ пакетов).
        args+=(--cache-from "type=registry,ref=${CACHE_FROM:-${cache_ref}}")
        if [ "${PUSH}" = true ]; then
            args+=(--cache-to "type=registry,ref=${CACHE_TO:-${cache_ref}},mode=max")
        fi
    fi

    if [ "${PUSH}" = true ]; then
        args+=(--push)
    elif [ "${LOAD}" = true ]; then
        args+=(--load)
    fi

    args+=("${REPO_ROOT}")

    log "docker ${args[*]}"
    docker "${args[@]}"
    ok "готов базовый образ ${image}"
}

if [ "${ALL}" = true ]; then
    for p in $(list_platforms); do build_one "${p}"; done
else
    [ -n "${PLATFORM}" ] || { usage; die "не указана --platform"; }
    build_one "${PLATFORM}"
fi
