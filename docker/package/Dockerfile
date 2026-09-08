# syntax=docker/dockerfile:1.7
# ============================================================================
# УНИВЕРСАЛЬНЫЙ ШАБЛОН СБОРКИ ROS 2-ПАКЕТА (п. 3.3 ТЗ)
# ----------------------------------------------------------------------------
# Ничего специфичного для конкретного пакета здесь нет. Всё приходит
# аргументами из packages/<name>.env:
#
#   docker buildx build -f docker/package/Dockerfile \
#     --build-arg BASE_IMAGE=ghcr.io/victoryurochkin/ros2-cuda-base:jetson-agx-orin-jp62 \
#     --build-arg PKG_NAME=fast_lio2 \
#     --build-arg PKG_REPO_URL=https://github.com/hku-mars/FAST_LIO \
#     --build-arg PKG_REF=ROS2 \
#     --build-arg CUDA_ARCHITECTURES=87 \
#     --platform linux/arm64 .
#
# Двухстадийная сборка: stage `builder` держит исходники, ccache и build/,
# stage `runtime` получает только install/ — образ меньше на 1.5-3 ГБ.
# CUDA Toolkit остаётся и в runtime: по ТЗ nvcc должен быть в образе.
# ============================================================================

ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS builder

ARG PKG_NAME
ARG PKG_REPO_URL
ARG PKG_REF=main
ARG PKG_SUBDIR=""
# Файл .repos со сторонними зависимостями (livox_ros_driver2, Sophus, ...)
ARG DEPS_REPOS_FILE=""
# Дополнительные apt-пакеты, специфичные для собираемого пакета
ARG APT_DEPS=""
# Дополнительные аргументы CMake (например -DUSE_CUDA=ON)
ARG PKG_CMAKE_ARGS=""
ARG CUDA_ARCHITECTURES=87
ARG PARALLEL_WORKERS=2
ARG COLCON_ARGS=""
# Скрипт, выполняемый ДО colcon build: для не-ROS зависимостей, которые
# ставятся классическим cmake && make install (например Livox-SDK2).
ARG PREBUILD_SCRIPT=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /opt/overlay

# --- 1. Дополнительные apt-зависимости пакета -----------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    if [ -n "${APT_DEPS}" ]; then \
        apt-get update && apt-get install -y --no-install-recommends ${APT_DEPS}; \
    fi

# --- 2. Зависимости из .repos (если объявлены) ----------------------------
COPY packages/ /opt/manifests/packages/
RUN set -euo pipefail; \
    mkdir -p src; \
    if [ -n "${DEPS_REPOS_FILE}" ] && [ -f "/opt/manifests/${DEPS_REPOS_FILE}" ]; then \
        vcs import src < "/opt/manifests/${DEPS_REPOS_FILE}"; \
    fi

# --- 3. Клонирование целевого пакета --------------------------------------
# Отдельным слоем и последним из исходников: смена ветки пакета не
# инвалидирует слои с зависимостями.
RUN --mount=type=cache,target=/root/.cache/git \
    set -euo pipefail; \
    git clone --recursive --depth 1 --branch "${PKG_REF}" \
        "${PKG_REPO_URL}" "src/${PKG_NAME}" \
    || ( git clone --recursive "${PKG_REPO_URL}" "src/${PKG_NAME}" \
         && git -C "src/${PKG_NAME}" checkout "${PKG_REF}" \
         && git -C "src/${PKG_NAME}" submodule update --init --recursive ); \
    if [ -n "${PKG_SUBDIR}" ]; then \
        mv "src/${PKG_NAME}/${PKG_SUBDIR}" "src/__tmp" && \
        rm -rf "src/${PKG_NAME}" && mv "src/__tmp" "src/${PKG_NAME}"; \
    fi; \
    git -C "src/${PKG_NAME}" log -1 --format='%H %ci %s' > /opt/overlay/SOURCE_REVISION || true

# --- 4. Разрешение ROS-зависимостей ---------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -euo pipefail; \
    apt-get update; \
    # Скрипты ROS не совместимы с set -u: setup.bash читает
    # AMENT_TRACE_SETUP_FILES, которая по умолчанию не задана.
    set +u; source /opt/ros/${ROS_DISTRO}/setup.bash; set -u; \
    rosdep install --from-paths src --ignore-src -y \
        --rosdistro "${ROS_DISTRO}" \
        --skip-keys "livox_ros_driver livox_ros_driver2 fastcdr rti-connext-dds-6.0.1" \
        || echo "WARNING: rosdep вернул ошибку, продолжаем (часть ключей может отсутствовать)"

# --- 4b. Пре-сборка не-ROS зависимостей -----------------------------------
RUN set -euo pipefail; \
    if [ -n "${PREBUILD_SCRIPT}" ] && [ -f "/opt/manifests/${PREBUILD_SCRIPT}" ]; then \
        echo ">>> prebuild: ${PREBUILD_SCRIPT}"; \
        chmod +x "/opt/manifests/${PREBUILD_SCRIPT}"; \
        PARALLEL_WORKERS="${PARALLEL_WORKERS}" OVERLAY_SRC=/opt/overlay/src \
            bash "/opt/manifests/${PREBUILD_SCRIPT}"; \
    fi

# --- 5. Сборка с поддержкой CUDA ------------------------------------------
# CMAKE_CUDA_ARCHITECTURES передаётся ВСЕМ пакетам оверлея: пакеты, в которых
# есть enable_language(CUDA), соберут device-код ровно под целевую SM.
# CUDACXX задаётся явно — под QEMU автодетект nvcc иногда промахивается.
ENV CUDACXX=${CUDA_HOME}/bin/nvcc
RUN --mount=type=cache,target=/root/.ccache \
    set -euo pipefail; \
    # Скрипты ROS не совместимы с set -u: setup.bash читает
    # AMENT_TRACE_SETUP_FILES, которая по умолчанию не задана.
    set +u; source /opt/ros/${ROS_DISTRO}/setup.bash; set -u; \
    colcon build \
        --merge-install \
        --parallel-workers "${PARALLEL_WORKERS}" \
        --event-handlers console_direct+ \
        ${COLCON_ARGS} \
        --cmake-args \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
            -DCMAKE_CUDA_COMPILER="${CUDA_HOME}/bin/nvcc" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            ${PKG_CMAKE_ARGS}

# =============================== runtime ====================================
FROM ${BASE_IMAGE} AS runtime

ARG PKG_NAME
ARG PKG_REPO_URL
ARG PKG_REF
ARG APT_DEPS=""
ARG CUDA_ARCHITECTURES=87
ARG PLATFORM_ID
ARG BUILD_MODE=native

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    if [ -n "${APT_DEPS}" ]; then \
        apt-get update && apt-get install -y --no-install-recommends ${APT_DEPS}; \
    fi

COPY --from=builder /opt/overlay/install /opt/overlay/install
COPY --from=builder /opt/overlay/SOURCE_REVISION /opt/overlay/SOURCE_REVISION

ENV OVERLAY_WS=/opt/overlay \
    PKG_NAME=${PKG_NAME}

LABEL org.opencontainers.image.title="${PKG_NAME}" \
      org.opencontainers.image.source="${PKG_REPO_URL}" \
      org.opencontainers.image.revision="${PKG_REF}" \
      ru.armmeh.platform="${PLATFORM_ID}" \
      ru.armmeh.build-mode="${BUILD_MODE}" \
      ru.armmeh.cuda-architectures="${CUDA_ARCHITECTURES}"

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
