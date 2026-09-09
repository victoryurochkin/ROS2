#!/usr/bin/env bash
# ============================================================================
# Подготовка Livox-стека для сборки под ROS 2.
# Выполняется внутри контейнера целевой архитектуры, ДО colcon build.
#
# Две задачи:
#
# 1) Livox-SDK2 — не ROS-пакет, colcon его не увидит. Ставится классическим
#    cmake/make install в /usr/local.
#
# 2) livox_ros_driver2 не собирается обычным colcon: в репозитории НЕТ
#    package.xml, вместо него лежат package_ROS1.xml и package_ROS2.xml, а
#    выбор делает скрипт build.sh, который запускает свой собственный
#    colcon build на весь воркспейс. Нам такой сценарий не подходит — мы
#    собираем весь оверлей одним colcon'ом. Поэтому берём из build.sh только
#    то, что нужно: подкладываем package_ROS2.xml как package.xml.
#    Выбор ветки кода в CMakeLists делают -DROS_EDITION=ROS2 и -DHUMBLE_ROS,
#    они передаются через PKG_CMAKE_ARGS манифеста.
# ============================================================================
set -euo pipefail

JOBS="${PARALLEL_WORKERS:-2}"
OVERLAY_SRC="${OVERLAY_SRC:-/opt/overlay/src}"

# --- 1. Livox-SDK2 ---------------------------------------------------------
if [ -f /usr/local/lib/liblivox_lidar_sdk_static.a ]; then
    echo ">>> Livox-SDK2 уже установлен, пропускаем"
else
    SRC=/tmp/Livox-SDK2
    git clone --depth 1 https://github.com/Livox-SDK/Livox-SDK2.git "${SRC}"
    cmake -S "${SRC}" -B "${SRC}/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "${SRC}/build" --parallel "${JOBS}"
    cmake --install "${SRC}/build"
    # Под QEMU на jammy (glibc 2.35) ldconfig стабильно падает с SIGSEGV —
    # это дефект эмуляции, а не сборки: на noble и на нативном ARM тот же
    # вызов проходит. Кеш ld.so нам не нужен, пути к библиотекам заданы
    # через LD_LIBRARY_PATH в базовом образе.
    ldconfig || echo "WARNING: ldconfig завершился с ошибкой (известная проблема QEMU), продолжаем"
    rm -rf "${SRC}"
    echo ">>> Livox-SDK2 установлен"
fi

# --- 2. package.xml для livox_ros_driver2 ---------------------------------
DRV="${OVERLAY_SRC}/livox_ros_driver2"
if [ -d "${DRV}" ]; then
    if [ -f "${DRV}/package_ROS2.xml" ]; then
        cp -f "${DRV}/package_ROS2.xml" "${DRV}/package.xml"
        echo ">>> livox_ros_driver2: package_ROS2.xml -> package.xml"
    elif [ -f "${DRV}/package.xml" ]; then
        echo ">>> livox_ros_driver2: package.xml уже на месте"
    else
        echo "!!! livox_ros_driver2: не найден ни package.xml, ни package_ROS2.xml" >&2
        exit 1
    fi
else
    echo ">>> livox_ros_driver2 не найден в ${OVERLAY_SRC}, пропускаем"
fi
