# 04 — Отладка и типовые проблемы

Собрано по итогам работы с этой связкой. Каждый пункт воспроизводился на
практике; где причина внешняя, приведены ссылки на первоисточник.

---

## QEMU и кросс-сборка

### `ldconfig` падает с SIGSEGV под QEMU (Ubuntu 22.04)

Симптом — сборка обрывается на установке пакетов или в pre-build скрипте:

```
Processing triggers for libc-bin (2.35-0ubuntu3.14) ...
Segmentation fault (core dumped)
dpkg: error processing package libc-bin (--configure):
 installed libc-bin package post-installation script subprocess returned error exit status 139
```

Причина — дефект эмуляции, а не сборки. Установлено экспериментально:

| Основа | glibc | `ldconfig` под QEMU | На нативном ARM |
|---|---|---|---|
| Ubuntu 22.04 (jammy) | 2.35 | **SIGSEGV** | проходит |
| Ubuntu 24.04 (noble) | 2.39 | проходит | проходит |

То есть страдает только пара «qemu-aarch64 + glibc 2.35». Кеш `ld.so` для
сборки не нужен: пути к библиотекам CUDA задаются через `LD_LIBRARY_PATH` в
базовом образе, поэтому в pre-build скриптах вызов обёрнут в `|| echo
WARNING`. Внутри `dpkg`-триггера обойти нельзя — там кросс-сборка базового
образа JetPack 6.2.2 под QEMU остаётся неработоспособной.

**Рабочий путь для JP 6.2.2 — нативный ARM-раннер:**

```
Actions → base-images → Run workflow → runner_kind: github-arm
```

### `qemu: uncaught target signal 11` в `nvcc` или `cc1plus`

Отличается от предыдущего: падает компилятор, а не `ldconfig`. Обычно лечится
фиксацией версии QEMU (это делает `scripts/setup-qemu.sh`):

```bash
docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-aarch64
docker run --privileged --rm tonistiigi/binfmt:qemu-v8.1.5 --install arm64
```

### `exec format error` при запуске arm64-образа

binfmt не зарегистрирован в текущей сессии:

```bash
make qemu
```

**В WSL2 регистрация не переживает `wsl --shutdown` и перезагрузку Windows** —
повторяйте `make qemu` в начале каждой сессии. `scripts/verify-image.sh`
проверяет это заранее и сообщает явно, вместо серии невнятных FAIL.

### Сборку убивает OOM без внятного сообщения

Код выхода 137, лог обрывается на компиляции. Под эмуляцией расход памяти на
поток кратно выше нативного:

```bash
PARALLEL_WORKERS=1 make package PACKAGE=fast_lio2 PLATFORM=jetson-orin-nano-jp7 MODE=cross
```

### Кросс-сборка идёт неприлично долго

Норма. Замеры на этом проекте: базовый образ JP 7.2 на нативном ARM-раннере —
10–15 мин при холодном кеше и ~5 мин при прогретом; та же сборка под QEMU на
16-ядерном x86 — около часа. Пакет `fast_lio2` под QEMU: `colcon build` 26
минут против 51 секунды нативно, то есть замедление примерно в 30 раз.

---

## Базовый образ Jetson

### `E: Unable to locate package cuda-toolkit-12-6`

Не подключился apt-репозиторий Jetson. Проверьте `L4T_SUITE` в
`platforms/*.env`. Соответствие: JP 6.2.2 → `r36.5`, JP 6.2.1 → `r36.4`,
JP 7.2 → `r39.2`.

### В JetPack 7 нет SoC-репозитория

Для JP 6.x пакеты разнесены по `common` и SoC-ветке (`t234` для Orin). **Для
r39.2 SoC-репозитория не существует.** Проверены все правдоподобные варианты —
`t234`, `t264`, `t23x`, `t26x`, `sbsa`, `aarch64`, `orin`, `thor`, `generic` —
все дают 404. Всё содержимое, включая `cuda-toolkit-13-2`, `libcudnn9-dev-cuda-13`
и `libnvinfer-dev`, лежит в `common`.

Поэтому в `platforms/jetson-orin-nano-jp7.env` задано `L4T_SOC=""`, а Dockerfile
подключает SoC-ветку условно.

### `File has unexpected size ... Mirror sync in progress?`

```
E: Failed to fetch https://repo.download.nvidia.com/jetson/common/dists/r39.2/main/binary-arm64/Packages.gz
   File has unexpected size (63810 != 63578). Mirror sync in progress?
```

Индексы на edge-узлах CDN NVIDIA расходятся между собой: разные узлы отдают
разные версии `Packages.gz` при одном `Release`. Ошибка плавающая — при
повторном запуске числа меняются местами. Усугубляется тем, что
`/var/lib/apt/lists` смонтирован как cache-mount и хранит старый `Release`.

Обход в `docker/package/Dockerfile`: списки сбрасываются перед обновлением,
включены повторы, а неудача самого `apt-get update` не валит шаг — пакеты
NVIDIA для `rosdep` и для сборочных зависимостей не нужны, они берутся из
репозиториев Ubuntu и ROS.

### Установка L4T-пакета падает в postinst

Обычно отсутствует `/etc/nv_tegra_release`. Dockerfile создаёт его до
`apt install`. Не ставьте `nvidia-l4t-core` и другие рантайм-пакеты BSP внутри
контейнера — их подмонтирует NVIDIA Container Runtime с хоста.

---

## Сборка пакетов

### `LIVOX_INTERFACES_INCLUDE_DIRECTORIES ... set to NOTFOUND`

```
CMake Error: The following variables are used in this project, but they are set to NOTFOUND:
  /opt/overlay/src/livox_ros_driver2/LIVOX_INTERFACES_INCLUDE_DIRECTORIES
CMake Warning: Manually-specified variables were not used by the project:
  HUMBLE_ROS
```

Upstream `Livox-SDK/livox_ros_driver2` **не собирается штатным colcon**. Это
незакрытый дефект самого драйвера, воспроизводится и вне нашей системы сборки,
в том числе на Jazzy: см. issues
[#131](https://github.com/Livox-SDK/livox_ros_driver2/issues/131) и
[#223](https://github.com/Livox-SDK/livox_ros_driver2/issues/223).

Показательна вторая строка: `HUMBLE_ROS` помечен как неиспользованный, то есть
документированный способ выбора ROS-редакции в текущем master уже не работает.

**Решение — форк [`Ericsii/livox_ros_driver2`](https://github.com/Ericsii/livox_ros_driver2)**,
на который опирается большинство ROS 2-портов FAST-LIO. Он собирается обычным
`colcon build`, без `build.sh`, без подмены `package.xml` и без
`-DROS_EDITION`. Ветка по умолчанию — `feature/use-standard-unit`; она указана
явно в `packages/fast_lio2.repos`.

### `'is_convertible_v' is not a member of 'std'` при сборке на Jazzy

```
error: 'is_convertible_v' is not a member of 'std'; did you mean 'is_convertible'?
   RCLCPP_INFO(this->get_logger(), "Initialize the map kdtree");
```

Ошибка возникает внутри макросов `RCLCPP_*`, то есть в заголовках rclcpp, а не
в коде пакета. `std::is_convertible_v` появился в C++17, а `hku-mars/FAST_LIO`
фиксирует стандарт C++14. В Humble заголовки rclcpp ещё компилировались под
C++14, в Jazzy — нет.

Подтверждено двумя независимыми прогонами (нативным и кросс) на
`jetson-orin-nano-jp7`. Это несовместимость пакета с дистрибутивом, а не
дефект системы сборки: FAST-LIO2 объявлен для Humble, что и зафиксировано в
`SUPPORTED_ROS_DISTROS` манифеста.

### `Could not find a package configuration file provided by "catkin"`

Собираемый пакет — ROS 1. Проверьте `<build_type>` в его `package.xml` и
наличие ветки с портом. У `hku-mars/FAST-LIVO2` ветки ROS 2 нет вообще —
нужен форк сообщества.

### Исполняемый файл «не найден» при верификации, хотя сборка прошла

colcon кладёт бинарники в `install/lib/<имя ROS-пакета>/`, а не
`install/lib/<имя образа>/`. Для FAST-LIO2 это `fast_lio`, а образ называется
`fast_lio2`. Заполните `ROS_PACKAGE_NAME` в манифесте.

### `AMENT_TRACE_SETUP_FILES: unbound variable`

Скрипты ROS не совместимы с `set -u`. Оборачивайте sourcing:

```bash
set +u; source /opt/ros/${ROS_DISTRO}/setup.bash; set -u
```

---

## Рантайм на устройстве

### `cudaGetDeviceCount failed: no CUDA-capable device is detected`

На Jetson забыт `--runtime nvidia`. Флаг `--gpus all` там **не работает**:

```bash
sudo docker run --rm --runtime nvidia <image> ...
```

### `CUDA driver version is insufficient for CUDA runtime version`

Версия CUDA в образе выше драйвера на устройстве. Классический случай — образ
JetPack 7 (CUDA 13.2) на JetPack 6.2.2 (драйвер 12.6). Обратной совместимости
нет.

```bash
head -1 /etc/nv_tegra_release
docker inspect <image> --format '{{index .Config.Labels "ru.armmeh.l4t-suite"}}'
```

### `no kernel image is available for execution on the device`

Device-код собран не под ту SM:

```bash
docker run --rm --runtime nvidia <image> \
  cuobjdump --list-elf /opt/verify/install/lib/libcuda_verify_kernels.so
```

Для любого Orin должно быть `sm_87`.

---

## CI

### `denied: permission_denied: write_package`

Settings → Actions → General → Workflow permissions → **Read and write**.

### `403 Forbidden` при импорте registry-кеша

```
#8 importing cache manifest from ghcr.io/<owner>/ros2-cuda-base:<tag>-cache
#8 ERROR: failed to authorize: ... 403 Forbidden
```

Ожидаемо при первой сборке: кеша в реестре ещё нет. Сборку не прерывает.

### `No space left on device` на раннере

Штатный раннер даёт около 14 ГБ, базовый образ с CUDA занимает больше (JP 7.2
с cuDNN и TensorRT — 10.3 ГБ). Шаг «Освободить место на раннере» удаляет
предустановленные .NET, Android SDK и Haskell, освобождая ~25 ГБ.

При необходимости набор `JETSON_CUDA_PACKAGES` можно сократить: если TensorRT
не нужен, уберите `libnvinfer-dev` и `libnvinfer-plugin-dev` — это заметно
уменьшит образ.

### Метки `ubuntu-24.04-arm` не работают

ARM64-раннеры GitHub доступны бесплатно **только в публичных репозиториях**.

### Кеш не срабатывает, каждая сборка идёт с нуля

Registry-кеш пишется только при `--push`. Локальные сборки кеш читают, но не
обновляют. Прогретый кеш экономит много: повторная сборка базового образа
JP 7.2 локально из registry-кеша заняла 33 секунды вместо часа.

---

## Диагностика

```bash
# что внутри образа
docker run --rm -it <image> bash
nvcc --version
ros2 pkg list | wc -l
cuobjdump --list-elf /opt/verify/install/lib/libcuda_verify_kernels.so
cat /opt/overlay/SOURCE_REVISION

# ревизия пакета и способ сборки
docker inspect <image> --format '{{json .Config.Labels}}' | jq

# полный набор проверок
./scripts/verify-image.sh --image <image> --platform <id> --package <pkg>
```
