#!/usr/bin/env bash
# ============================================================================
# Зависимости FAST-LIVO2: всё из livox_ros2_stack.sh плюс Sophus.
#
# Sophus нужен нетемплейтный (double-only). Upstream FAST-LIVO2 требует
# конкретный коммит a621ff; ROS 2-порты используют тег 1.22.10, который
# собирается современным компилятором без правок. Берём тег, коммит оставлен
# в комментарии на случай проблем совместимости.
# ============================================================================
set -euo pipefail

JOBS="${PARALLEL_WORKERS:-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Livox-SDK2 + патч драйвера
bash "${HERE}/livox_ros2_stack.sh"

# --- Sophus ----------------------------------------------------------------
if [ -d /usr/local/include/sophus ] || [ -d /usr/include/sophus ]; then
    echo ">>> Sophus уже установлен, пропускаем"
    exit 0
fi

# Быстрый путь: бинарный пакет, если он есть в репозитории ROS.
if apt-get install -y --no-install-recommends "ros-${ROS_DISTRO}-sophus" 2>/dev/null; then
    echo ">>> Sophus установлен из apt (ros-${ROS_DISTRO}-sophus)"
    exit 0
fi

SRC=/tmp/Sophus
git clone --depth 1 --branch 1.22.10 https://github.com/strasdat/Sophus.git "${SRC}"
# Альтернатива при проблемах совместимости:
#   git -C "${SRC}" fetch --depth 50 origin && git -C "${SRC}" checkout a621ff
cmake -S "${SRC}" -B "${SRC}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SOPHUS_TESTS=OFF \
    -DBUILD_SOPHUS_EXAMPLES=OFF
cmake --build "${SRC}/build" --parallel "${JOBS}"
cmake --install "${SRC}/build"
ldconfig
rm -rf "${SRC}"
echo ">>> Sophus установлен из исходников"
