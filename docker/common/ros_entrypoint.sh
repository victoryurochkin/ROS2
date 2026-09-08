#!/usr/bin/env bash
# Точка входа: подключает underlay (/opt/ros/$ROS_DISTRO), верификатор CUDA
# и overlay с собранным пакетом, если он есть.
set -e

source "/opt/ros/${ROS_DISTRO}/setup.bash"

if [ -f /opt/verify/install/setup.bash ]; then
    source /opt/verify/install/setup.bash
fi

if [ -f /opt/overlay/install/setup.bash ]; then
    source /opt/overlay/install/setup.bash
fi

exec "$@"
