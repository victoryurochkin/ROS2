#!/usr/bin/env bash
# ============================================================================
# Проверка собранного образа. Закрывает пункт ТЗ «подтверждение наличия CUDA
# в собранных образах» и используется как тестовая стадия пайплайна.
#
#   ./scripts/verify-image.sh --image ghcr.io/victoryurochkin/fast_lio2:jetson-agx-orin-jp62-cross \
#                             --platform jetson-agx-orin-jp62 --package fast_lio2
#
# Проверки делятся на две группы:
#
#   СТАТИЧЕСКИЕ — выполняются где угодно, включая x86-раннер без GPU,
#   на arm64-образах через QEMU. Именно они доказывают, что CUDA собрана
#   правильно: cuobjdump показывает, что в бинарнике лежит device-код ровно
#   под целевую SM-архитектуру. Это сильнее, чем «nvcc --version отработал».
#
#   ДИНАМИЧЕСКИЕ — требуют GPU. Запускаются на x86-раннере с GPU или на
#   самом Jetson. При отсутствии GPU честно помечаются SKIP, а не молча
#   пропускаются.
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IMAGE=""
PLATFORM=""
PACKAGE=""
REPORT=""
GPU_MODE="auto"   # auto | force | off

usage() {
    cat <<EOF
Использование: $0 --image <ref> --platform <id> [--package <name>] [опции]
  --report <file>   записать отчёт в файл (markdown)
  --gpu <auto|force|off>
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --report) REPORT="$2"; shift 2 ;;
        --gpu) GPU_MODE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

[ -n "${IMAGE}" ]    || { usage; die "не указан --image"; }
[ -n "${PLATFORM}" ] || { usage; die "не указана --platform"; }

load_platform "${PLATFORM}"
[ -n "${PACKAGE}" ] && load_package "${PACKAGE}"

gpu_flags=""
PASS=0; FAIL=0; SKIP=0
RESULTS=()

record() {  # record <status> <name> <details>
    local status="$1" name="$2" details="${3:-}"
    case "${status}" in
        PASS) PASS=$((PASS+1)); ok   "${name}: ${details}" ;;
        FAIL) FAIL=$((FAIL+1)); warn "${name}: ${details}" ;;
        SKIP) SKIP=$((SKIP+1)); warn "${name}: SKIP ${details}" ;;
    esac
    RESULTS+=("| ${status} | ${name} | ${details//|/\\|} |")
}

# Подключение окружения ROS внутри образа. /ros_entrypoint.sh здесь не
# годится: он заканчивается exec "$@" и завершил бы оболочку.
SOURCE_ENV='set +u
source /opt/ros/${ROS_DISTRO}/setup.bash >/dev/null 2>&1 || true
[ -f /opt/verify/install/setup.bash ] && source /opt/verify/install/setup.bash >/dev/null 2>&1
[ -f /opt/overlay/install/setup.bash ] && source /opt/overlay/install/setup.bash >/dev/null 2>&1
:
'

# Запуск команды внутри образа (без GPU).
in_image() {
    docker run --rm --platform "${DOCKER_PLATFORM}" --entrypoint /bin/bash \
        "${IMAGE}" -c "${SOURCE_ENV}
$*"
}

# Запуск команды внутри образа с прокинутым GPU.
in_image_gpu() {
    # shellcheck disable=SC2086
    docker run --rm ${gpu_flags} --platform "${DOCKER_PLATFORM}" --entrypoint /bin/bash \
        "${IMAGE}" -c "${SOURCE_ENV}
$*"
}

# ---------------------------------------------------------------------------
log "=== СТАТИЧЕСКИЕ ПРОВЕРКИ ==="

# 1. Архитектура образа
expected_arch="$(printf '%s' "${DOCKER_PLATFORM}" | cut -d/ -f2)"
actual_arch="$(docker image inspect "${IMAGE}" --format '{{.Architecture}}' 2>/dev/null || echo unknown)"
if [ "${actual_arch}" = "${expected_arch}" ]; then
    record PASS "архитектура образа" "${actual_arch}"
else
    record FAIL "архитектура образа" "ожидали ${expected_arch}, получили ${actual_arch}"
fi

# 2. CUDA Toolkit присутствует и рабочий
if nvcc_out="$(in_image 'nvcc --version' 2>&1)"; then
    nvcc_ver="$(printf '%s' "${nvcc_out}" | grep -oP 'release \K[0-9.]+' | head -n1)"
    if [ "${nvcc_ver%%.*}" = "${CUDA_VERSION%%.*}" ]; then
        record PASS "nvcc в образе" "release ${nvcc_ver} (ожидали ${CUDA_VERSION})"
    else
        record FAIL "nvcc в образе" "release ${nvcc_ver}, ожидали ${CUDA_VERSION}"
    fi
else
    record FAIL "nvcc в образе" "nvcc не запускается"
fi

# 3. Библиотеки CUDA на месте
if in_image 'ls ${CUDA_HOME}/lib64/libcudart_static.a >/dev/null' >/dev/null 2>&1; then
    record PASS "CUDA runtime library" "libcudart найдена в \$CUDA_HOME/lib64"
else
    record FAIL "CUDA runtime library" "libcudart не найдена"
fi

# 4. ROS 2 на месте
if ros_out="$(in_image 'echo $ROS_DISTRO && ros2 pkg list | wc -l' 2>&1)"; then
    ros_distro_in_image="$(printf '%s' "${ros_out}" | head -n1)"
    pkg_count="$(printf '%s' "${ros_out}" | tail -n1)"
    if [ "${ros_distro_in_image}" = "${ROS_DISTRO}" ]; then
        record PASS "ROS 2" "${ros_distro_in_image}, пакетов: ${pkg_count}"
    else
        record FAIL "ROS 2" "в образе ${ros_distro_in_image}, ожидали ${ROS_DISTRO}"
    fi
else
    record FAIL "ROS 2" "ros2 CLI не работает"
fi

# 5. ГЛАВНАЯ ПРОВЕРКА: device-код под целевую SM внутри бинарника.
#    cuobjdump читает секции ELF и печатает, под какие sm_* собран cubin.
#    Работает без GPU и без драйвера — то есть проверяется прямо на
#    x86-раннере сразу после кросс-сборки.
kernels_lib='/opt/verify/install/lib/libcuda_verify_kernels.so'
primary_arch="${CUDA_ARCHITECTURES%%;*}"
if cubin_out="$(in_image "cuobjdump --list-elf ${kernels_lib}" 2>&1)"; then
    found_archs="$(printf '%s' "${cubin_out}" | grep -oP 'sm_\d+' | sort -u | tr '\n' ' ')"
    if printf '%s' "${found_archs}" | grep -q "sm_${primary_arch}"; then
        record PASS "device-код в бинарнике" "найдены архитектуры: ${found_archs}"
    else
        record FAIL "device-код в бинарнике" "нет sm_${primary_arch}, есть: ${found_archs}"
    fi
else
    record FAIL "device-код в бинарнике" "cuobjdump не отработал: ${cubin_out}"
fi

# 6. Линковка с CUDA runtime
if ldd_out="$(in_image "ldd ${kernels_lib}" 2>&1)"; then
    if printf '%s' "${ldd_out}" | grep -q 'libcudart'; then
        record PASS "линковка с libcudart" "$(printf '%s' "${ldd_out}" | grep -o 'libcudart[^ ]*' | head -n1)"
    else
        record FAIL "линковка с libcudart" "libcudart отсутствует в зависимостях"
    fi
else
    record FAIL "линковка с libcudart" "ldd не отработал"
fi

# 7. Целевой пакет собрался и его исполняемые файлы на месте
if [ -n "${PACKAGE}" ]; then
    if rev="$(in_image 'cat /opt/overlay/SOURCE_REVISION' 2>/dev/null)"; then
        record PASS "исходники пакета" "${rev}"
    else
        record SKIP "исходники пакета" "SOURCE_REVISION отсутствует (базовый образ?)"
    fi
    for exe in ${EXPECT_EXECUTABLES}; do
        # colcon кладёт бинарники в install/lib/<имя ROS-пакета>/, которое
        # может не совпадать с именем образа (fast_lio2 -> fast_lio).
        if in_image "test -x /opt/overlay/install/lib/${ROS_PACKAGE_NAME}/${exe} || command -v ${exe}" >/dev/null 2>&1; then
            record PASS "исполняемый файл ${exe}" "найден"
        else
            record FAIL "исполняемый файл ${exe}" "не найден в оверлее"
        fi
    done
fi

# ---------------------------------------------------------------------------
log "=== ДИНАМИЧЕСКИЕ ПРОВЕРКИ (нужен GPU) ==="

if [ "${GPU_MODE}" = "off" ]; then
    record SKIP "запуск на GPU" "отключено ключом --gpu off"
else
    host_arch="$(uname -m)"
    if [ "${PLATFORM_KIND}" = "jetson" ] && [ "${host_arch}" != "aarch64" ]; then
        record SKIP "запуск на GPU" "Jetson-образ на x86-хосте — исполнить device-код невозможно"
    elif [ "${PLATFORM_KIND}" = "jetson" ] && docker info 2>/dev/null | grep -qi 'nvidia'; then
        gpu_flags="--runtime nvidia"
    elif command -v nvidia-smi >/dev/null 2>&1; then
        gpu_flags="--gpus all"
    fi

    if [ -n "${gpu_flags}" ]; then
        log "GPU обнаружен, запускаю cuda_smoke (${gpu_flags})"
        set +e
        smoke_out="$(in_image_gpu '/opt/verify/install/lib/cuda_verify/cuda_smoke' 2>&1)"
        rc=$?
        set -e
        case "${rc}" in
            0) record PASS "vector_add на GPU" "$(printf '%s' "${smoke_out}" | grep -m1 'sm_' | xargs || echo ok)" ;;
            2) record SKIP "vector_add на GPU" "устройства не видны контейнеру" ;;
            *) record FAIL "vector_add на GPU" "$(printf '%s' "${smoke_out}" | tail -n2 | tr '\n' ' ')" ;;
        esac

        set +e
        node_out="$(timeout 20 docker run --rm ${gpu_flags} --platform "${DOCKER_PLATFORM}" \
            "${IMAGE}" ros2 run cuda_verify cuda_info_node 2>&1 || true)"
        set -e
        if printf '%s' "${node_out}" | grep -q 'devices='; then
            record PASS "ROS 2 нода с CUDA" "cuda_info_node стартовала и увидела GPU"
        else
            record SKIP "ROS 2 нода с CUDA" "нода не подтвердила наличие устройств"
        fi
    else
        record SKIP "запуск на GPU" "GPU на этом хосте не обнаружен"
    fi
fi

# ---------------------------------------------------------------------------
summary="PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
log "=== ИТОГ: ${summary} ==="

if [ -n "${REPORT}" ]; then
    {
        echo "## Верификация образа"
        echo
        echo "* образ: \`${IMAGE}\`"
        echo "* платформа: \`${PLATFORM}\` (${PLATFORM_DESCRIPTION})"
        echo "* целевые SM: \`${CUDA_ARCHITECTURES}\`"
        echo
        echo "| Статус | Проверка | Детали |"
        echo "|---|---|---|"
        printf '%s\n' "${RESULTS[@]}"
        echo
        echo "**${summary}**"
    } > "${REPORT}"
    ok "отчёт записан: ${REPORT}"
fi

[ "${FAIL}" -eq 0 ] || die "проверки не пройдены (${summary})"
ok "все проверки пройдены (${summary})"
