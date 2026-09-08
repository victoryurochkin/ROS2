#!/usr/bin/env bash
# Общие функции для скриптов сборки. Подключается через `source`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --- вывод -----------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n' "${C_BLU}" "${C_RST}" "$*" >&2; }
ok()   { printf '%s OK %s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%sWARN%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

# --- загрузка описания платформы -------------------------------------------
# load_platform <platform-id>
load_platform() {
    local id="$1"
    local file="${REPO_ROOT}/platforms/${id}.env"
    [ -f "${file}" ] || die "нет описания платформы: ${file}"
    # значения по умолчанию, чтобы set -u не ругался на необязательные поля
    L4T_SUITE=""; L4T_SOC=""; L4T_RELEASE_MAJOR=""; L4T_RELEASE_MINOR=""
    JETSON_CUDA_PACKAGES=""; CUDA_HOME=""; ROS_BUILD_MODE="binary"
    SELF_HOSTED_RUNNER=""; SUPPORTS_CROSS="false"
    # shellcheck disable=SC1090
    set -a; source "${file}"; set +a
    ok "платформа: ${PLATFORM_ID} (${DOCKER_PLATFORM}, ROS ${ROS_DISTRO}, sm ${CUDA_ARCHITECTURES})"
}

# --- загрузка манифеста пакета ---------------------------------------------
# load_package <package-name>
load_package() {
    local name="$1"
    local file="${REPO_ROOT}/packages/${name}.env"
    [ -f "${file}" ] || die "нет манифеста пакета: ${file}"
    PKG_SUBDIR=""; DEPS_REPOS_FILE=""; PREBUILD_SCRIPT=""
    APT_DEPS=""; PKG_CMAKE_ARGS=""; COLCON_ARGS=""; EXPECT_EXECUTABLES=""
    ROS_PACKAGE_NAME=""; SUPPORTED_ROS_DISTROS=""
    # shellcheck disable=SC1090
    set -a; source "${file}"; set +a
    [ -n "${PKG_REPO_URL:-}" ] || die "в манифесте ${name} не задан PKG_REPO_URL"
    # Имя ROS-пакета часто отличается от имени образа (fast_lio2 -> fast_lio).
    [ -n "${ROS_PACKAGE_NAME}" ] || ROS_PACKAGE_NAME="${PKG_NAME}"
    export ROS_PACKAGE_NAME
    ok "пакет: ${PKG_NAME} (ROS-пакет ${ROS_PACKAGE_NAME}) @ ${PKG_REPO_URL}#${PKG_REF}"
}

list_platforms() {
    find "${REPO_ROOT}/platforms" -name '*.env' -printf '%f\n' | sed 's/\.env$//' | sort
}

list_packages() {
    find "${REPO_ROOT}/packages" -maxdepth 1 -name '*.env' -printf '%f\n' \
        | sed 's/\.env$//' | grep -v '^_' | sort
}

# --- реестр образов --------------------------------------------------------
registry_prefix() {
    local reg="${REGISTRY:-ghcr.io}"
    local owner="${IMAGE_OWNER:-${GITHUB_REPOSITORY_OWNER:-local}}"
    printf '%s/%s' "${reg}" "$(printf '%s' "${owner}" | tr '[:upper:]' '[:lower:]')"
}

base_image_ref() {
    printf '%s/ros2-cuda-base:%s' "$(registry_prefix)" "$1"
}

package_image_ref() {
    # <name>:<platform>[-<suffix>]
    local name="$1" platform="$2" suffix="${3:-}"
    if [ -n "${suffix}" ]; then
        printf '%s/%s:%s-%s' "$(registry_prefix)" "${name}" "${platform}" "${suffix}"
    else
        printf '%s/%s:%s' "$(registry_prefix)" "${name}" "${platform}"
    fi
}

# --- buildx ----------------------------------------------------------------
ensure_builder() {
    local name="${BUILDX_BUILDER:-ros2-cuda-builder}"
    if ! docker buildx inspect "${name}" >/dev/null 2>&1; then
        log "создаю buildx-билдер ${name}"
        docker buildx create --name "${name}" --driver docker-container \
            --driver-opt network=host --use >/dev/null
    else
        docker buildx use "${name}"
    fi
    docker buildx inspect --bootstrap "${name}" >/dev/null
}
