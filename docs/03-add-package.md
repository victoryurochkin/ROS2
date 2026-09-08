# 03 — Добавление нового ROS 2-пакета

Требование ТЗ — «добавлять новые пакеты с минимальными изменениями». Минимум
здесь — **один файл**. Ни Dockerfile, ни workflow, ни скрипты не меняются.

## Минимальный случай

Пакет, который собирается штатным `colcon build` и все зависимости которого
разрешаются через `rosdep`:

```bash
cp packages/_template.env packages/my_slam.env
```

```bash
# packages/my_slam.env
PKG_NAME="my_slam"
PKG_REPO_URL="https://github.com/example/my_slam"
PKG_REF="v1.2.0"
EXPECT_EXECUTABLES="my_slam_node"
```

Всё:

```bash
make package PACKAGE=my_slam PLATFORM=jetson-agx-orin-jp62 MODE=cross
```

В CI пакет появится в матрице автоматически при ручном запуске
(`workflow_dispatch` → поле `package`).

## Поля манифеста

| Поле | Обязательно | Назначение |
|---|---|---|
| `PKG_NAME` | да | имя образа и имя каталога в `src/` |
| `ROS_PACKAGE_NAME` | нет | имя ROS-пакета, если отличается от `PKG_NAME`. По нему colcon кладёт бинарники в `install/lib/<имя>/`, и по нему же идёт проверка образа |
| `PKG_REPO_URL` | да | git-репозиторий |
| `PKG_REF` | да | ветка, тег или коммит |
| `SUPPORTED_ROS_DISTROS` | нет | на каких дистрибутивах пакет проверен; при несовпадении с платформой скрипт предупредит |
| `PKG_SUBDIR` | нет | если ROS-пакет лежит в подкаталоге репозитория |
| `DEPS_REPOS_FILE` | нет | `.repos`-файл с зависимостями для `vcs import` |
| `PREBUILD_SCRIPT` | нет | скрипт для не-ROS зависимостей (cmake/make install) |
| `APT_DEPS` | нет | дополнительные системные пакеты |
| `PKG_CMAKE_ARGS` | нет | флаги CMake, например `-DUSE_CUDA=ON` |
| `COLCON_ARGS` | нет | например `--packages-up-to my_slam` |
| `EXPECT_EXECUTABLES` | нет | что проверять в собранном образе |

## Случай с зависимостями из git

Создайте `packages/my_slam.repos` в формате `vcs`:

```yaml
repositories:
  livox_ros_driver2:
    type: git
    url: https://github.com/Livox-SDK/livox_ros_driver2.git
    version: master
```

и укажите его в манифесте:

```bash
DEPS_REPOS_FILE="packages/my_slam.repos"
```

Зависимости импортируются **до** клонирования целевого пакета, отдельным
слоем — смена ветки пакета не инвалидирует кеш зависимостей.

## Случай с не-ROS зависимостями

Библиотеки вроде Livox-SDK2 ставятся классическим `cmake && make install` и
colcon про них ничего не знает. Для них есть pre-build скрипт:

```bash
# packages/prebuild/my_deps.sh
#!/usr/bin/env bash
set -euo pipefail
git clone --depth 1 https://github.com/example/libfoo /tmp/libfoo
cmake -S /tmp/libfoo -B /tmp/libfoo/build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/libfoo/build --parallel "${PARALLEL_WORKERS:-2}"
cmake --install /tmp/libfoo/build
ldconfig
```

```bash
PREBUILD_SCRIPT="packages/prebuild/my_deps.sh"
```

Скрипт выполняется внутри контейнера целевой архитектуры, поэтому под QEMU он
тоже соберётся корректно. Не забудьте про `PARALLEL_WORKERS` — при кросс-сборке
он равен 2, и это не случайность (см. [04-troubleshooting.md](04-troubleshooting.md)).

## Пакет с CUDA-кодом

Если в пакете есть `.cu`-файлы и `enable_language(CUDA)` в CMakeLists, ничего
делать не нужно: система сборки уже передаёт всем пакетам оверлея

```
-DCMAKE_CUDA_ARCHITECTURES=<из platforms/*.env>
-DCMAKE_CUDA_COMPILER=$CUDA_HOME/bin/nvcc
```

Если пакет прячет CUDA за флагом — включите его в манифесте:

```bash
PKG_CMAKE_ARGS="-DUSE_CUDA=ON -DWITH_TENSORRT=ON"
```

Проверить, что device-код действительно попал в бинарник:

```bash
make verify PACKAGE=my_slam PLATFORM=jetson-agx-orin-jp62 MODE=cross
```

Скрипт верификации сам найдёт `.so` пакета, прогонит по нему `cuobjdump` и
покажет список SM-архитектур внутри.

## Сначала проверьте, что пакет вообще поддерживает ROS 2

Это не формальность. Из двух пакетов, предложенных в ТЗ как тестовые, один
под ROS 2 в upstream не собирается вовсе.

| Пакет | Что в upstream | Что делать |
|---|---|---|
| **FAST-LIO2** | `main` — ROS 1 (`catkin_make`, `roslaunch`). Порт под ROS 2 влит в отдельную ветку **`ROS2`** | `PKG_REF="ROS2"` |
| **FAST-LIVO2** | только `main`, и это **чистый ROS 1**: README требует Ubuntu 18.04–20.04, сборка через `catkin_make`. Ветки ROS 2 нет | использовать порт сообщества, см. `packages/fast_livo2.env` |

Чек-лист перед написанием манифеста:

1. Есть ли в репозитории `package.xml` с `<build_type>ament_cmake</build_type>`?
   Если там `catkin` — это ROS 1, colcon его не соберёт.
2. Есть ли ветка с портом? Смотрите список веток, а не только `main`.
3. Есть ли сабмодули? Тогда нужен `--recursive` — шаблон делает это всегда.
4. Как называется ROS-пакет в `CMakeLists.txt`? Если не так, как репозиторий —
   заполните `ROS_PACKAGE_NAME`.

## Пример: FAST-LIO2

`packages/fast_lio2.env` — рабочий пример со всеми механизмами сразу: ветка
порта `ROS2`, `ROS_PACKAGE_NAME=fast_lio` (в CMakeLists пакет называется
иначе, чем образ), `.repos` для `livox_ros_driver2`, pre-build скрипт и
`PKG_CMAKE_ARGS` с флагами выбора ROS-редакции.

Отдельная тонкость, на которую легко напороться: **`livox_ros_driver2` не
собирается обычным colcon**. В его репозитории нет `package.xml` — вместо него
лежат `package_ROS1.xml` и `package_ROS2.xml`, а выбирает нужный скрипт
`build.sh`, который запускает собственный `colcon build` на весь воркспейс.
Нам это не подходит: оверлей собирается одним вызовом colcon. Поэтому
pre-build скрипт берёт из `build.sh` только нужное — подкладывает
`package_ROS2.xml` как `package.xml`, а ветку кода в CMakeLists выбирают
`-DROS_EDITION=ROS2 -DHUMBLE_ROS=humble` из `PKG_CMAKE_ARGS`.

`packages/fast_livo2.env` — пример пакета, у которого upstream остался на
ROS 1: манифест указывает на ROS 2-порт сообщества и тянет ament-версию
`rpg_vikit` (оригинальный — catkin-проект) плюс Sophus. Инфраструктурного
кода при этом по-прежнему ноль.

## Добавление новой платформы

Симметрично: один файл в `platforms/`. Например, Jetson AGX Thor:

```bash
# platforms/jetson-thor-jp7.env
PLATFORM_ID="jetson-thor-jp7"
DOCKER_PLATFORM="linux/arm64"
BASE_DOCKERFILE="docker/base/Dockerfile.jetson"
BASE_FROM="ubuntu:24.04"
ROS_DISTRO="jazzy"
ROS_BASE_PACKAGE="ros-jazzy-ros-base"
L4T_SUITE="r39.2"
L4T_SOC="t264"          # Thor, не t234
L4T_RELEASE_MAJOR="39"
L4T_RELEASE_MINOR="2.0"
JETSON_CUDA_PACKAGES="cuda-toolkit-13-2 libcudnn9-dev-cuda-13"
CUDA_HOME="/usr/local/cuda-13.2"
CUDA_ARCHITECTURES="110"   # Blackwell, sm_110 — не 87
PLATFORM_KIND="jetson"
NATIVE_RUNNER="ubuntu-24.04-arm"
SUPPORTS_CROSS="true"
PLATFORM_DESCRIPTION="Jetson AGX Thor, JetPack 7.2, CUDA 13.2, ROS 2 Jazzy, sm_110"
```

Матрица CI подхватит платформу на следующем запуске без правки workflow.
