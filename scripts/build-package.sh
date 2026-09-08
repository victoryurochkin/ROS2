#!/usr/bin/env bash
# ============================================================================
# Сборка образа ROS 2-пакета на базе готового базового образа.
#
#   ./scripts/build-package.sh --package fast_lio2 --platform x86_64-cuda
#   ./scripts/build-package.sh --package fast_lio2 --platform jetson-agx-orin-jp62 \
#                              --mode cross --push
#
# --mode влияет только на тег и метку образа (native|cross): сам Dockerfile
# одинаков, разница в том, где выполняется сборка — на arm64-раннере или на
# x86 под QEMU. Это позволяет положить рядом два артефакта одной платформы
# и сравнить их (см. docs/05-verification.md).
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PACKAGE=""
PLATFORM=""
MODE="native"
PUSH=false
LOAD=true
BASE_OVERRIDE=""
EXTRA_TAG=""

usage() {
    cat <<EOF
Использование: $0 --package <name> --platform <id> [опции]

  --package <name>   манифест из packages/*.env: $(list_packages | tr '\n' ' ')
  --platform <id>    платформа из platforms/*.env: $(list_platforms | tr '\n' ' ')
  --mode <native|cross>  как помечать сборку (по умолчанию native)
  --base <image>     переопределить базовый образ
  --push             запушить результат
  --no-load          не загружать в локальный docker
  --tag <suffix>     дополнительный тег
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --package) PACKAGE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --base) BASE_OVERRIDE="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        --no-load) LOAD=false; shift ;;
        --tag) EXTRA_TAG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

[ -n "${PACKAGE}" ]  || { usage; die "не указан --package"; }
[ -n "${PLATFORM}" ] || { usage; die "не указана --platform"; }
case "${MODE}" in native|cross) ;; *) die "--mode должен быть native или cross" ;; esac

load_platform "${PLATFORM}"
load_package  "${PACKAGE}"
ensure_builder

# Порты ROS 2 часто заявлены только под конкретный дистрибутив. Например,
# ROS 2-порт FAST-LIVO2 проверен на Humble, а платформа JetPack 7 использует
# Jazzy. Это не повод блокировать сборку, но повод предупредить.
if [ -n "${SUPPORTED_ROS_DISTROS}" ] && \
   ! printf ' %s ' "${SUPPORTED_ROS_DISTROS}" | grep -q " ${ROS_DISTRO} "; then
    warn "пакет ${PKG_NAME} заявлен для ROS: ${SUPPORTED_ROS_DISTROS}, а платформа ${PLATFORM} использует ${ROS_DISTRO}"
    warn "сборка продолжится, но результат не гарантирован"
fi

BASE_IMAGE="${BASE_OVERRIDE:-$(base_image_ref "${PLATFORM}")}"
IMAGE="$(package_image_ref "${PKG_NAME}" "${PLATFORM}" "${MODE}")"
CACHE_REF="$(package_image_ref "${PKG_NAME}" "${PLATFORM}" "${MODE}")-cache"

# Под QEMU параллелизм режем: эмулируемая сборка съедает память кратно
# больше нативной, и -j$(nproc) стабильно приводит к OOM на 7 ГБ раннере.
if [ "${MODE}" = "cross" ]; then
    WORKERS="${PARALLEL_WORKERS:-2}"
else
    WORKERS="${PARALLEL_WORKERS:-$(nproc)}"
fi

args=(
    buildx build
    --file "${REPO_ROOT}/docker/package/Dockerfile"
    --platform "${DOCKER_PLATFORM}"
    --tag "${IMAGE}"
    --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    --build-arg "PKG_NAME=${PKG_NAME}"
    --build-arg "PKG_REPO_URL=${PKG_REPO_URL}"
    --build-arg "PKG_REF=${PKG_REF}"
    --build-arg "PKG_SUBDIR=${PKG_SUBDIR}"
    --build-arg "DEPS_REPOS_FILE=${DEPS_REPOS_FILE}"
    --build-arg "PREBUILD_SCRIPT=${PREBUILD_SCRIPT}"
    --build-arg "APT_DEPS=${APT_DEPS}"
    --build-arg "PKG_CMAKE_ARGS=${PKG_CMAKE_ARGS}"
    --build-arg "COLCON_ARGS=${COLCON_ARGS}"
    --build-arg "CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}"
    --build-arg "PARALLEL_WORKERS=${WORKERS}"
    --build-arg "PLATFORM_ID=${PLATFORM_ID}"
    --build-arg "BUILD_MODE=${MODE}"
    --cache-from "type=registry,ref=${CACHE_REF}"
    --provenance=false
)

[ -n "${EXTRA_TAG}" ] && args+=(--tag "$(package_image_ref "${PKG_NAME}" "${PLATFORM}" "${MODE}")-${EXTRA_TAG}")

if [ "${PUSH}" = true ]; then
    args+=(--cache-to "type=registry,ref=${CACHE_REF},mode=max" --push)
elif [ "${LOAD}" = true ]; then
    args+=(--load)
fi

args+=("${REPO_ROOT}")

log "сборка ${PKG_NAME} для ${PLATFORM} (${MODE}), workers=${WORKERS}"
log "базовый образ: ${BASE_IMAGE}"
docker "${args[@]}"
ok "готов образ ${IMAGE}"

printf '%s\n' "${IMAGE}"
