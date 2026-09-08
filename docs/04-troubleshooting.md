# 04 — Отладка и типовые проблемы

Собрано по итогам работы с этой связкой; почти каждый пункт стоил времени.

---

## QEMU и кросс-сборка

### `qemu: uncaught target signal 11 (Segmentation fault)`

Падает `nvcc`, `cc1plus` или линковка PCL посреди кросс-сборки.

Причина — ошибки трансляции в старых сборках QEMU. Проверьте, какая версия
зарегистрирована:

```bash
docker run --privileged --rm tonistiigi/binfmt
```

Лечение — перерегистрация на фиксированной версии (это и делает
`scripts/setup-qemu.sh`):

```bash
docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-aarch64
docker run --privileged --rm tonistiigi/binfmt:qemu-v8.1.5 --install arm64
```

### `exec format error` при запуске arm64-образа

binfmt не зарегистрирован в текущей сессии. После перезагрузки хоста
регистрацию нужно повторить, если она не оформлена как systemd-юнит:

```bash
make qemu
```

### Сборку убивает OOM без внятного сообщения

Признак: шаг падает с кодом 137, в логе обрывается компиляция.

Под QEMU потребление памяти на поток кратно выше нативного. Уменьшите
параллелизм:

```bash
PARALLEL_WORKERS=1 make package PACKAGE=fast_lio2 PLATFORM=jetson-orin-nano-jp7 MODE=cross
```

На self-hosted Jetson-раннере добавьте swap:

```bash
sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
```

### Кросс-сборка идёт неприлично долго

Это нормально: под эмуляцией сборка медленнее нативной в 5–15 раз. Если время
критично — используйте нативные ARM-раннеры:

```
Actions → package-build → Run workflow → include_native_arm: true
```

---

## Базовый образ Jetson

### `E: Unable to locate package cuda-toolkit-12-6`

Не подключился apt-репозиторий Jetson. Проверьте `L4T_SUITE` в
`platforms/*.env`: он должен совпадать с суффиксом на устройстве.

```bash
# на Jetson
cat /etc/apt/sources.list.d/nvidia-l4t-apt-source.list
cat /etc/nv_tegra_release
```

Соответствие: JP 6.2.2 → `r36.5`, JP 6.2.1 → `r36.4`, JP 7.2 → `r39.2`.
Суффиксы старых релизов из публичного репозитория удаляются после выхода
следующего GA — если сборка внезапно перестала находить пакеты, проверьте,
не устарел ли `L4T_SUITE`.

### Установка L4T-пакета падает в postinst

Обычно это отсутствие `/etc/nv_tegra_release`. Dockerfile создаёт его до
`apt install`; если вы правили порядок слоёв — верните на место.

Второй источник — попытка поставить `nvidia-l4t-core` или другие рантайм-пакеты
BSP внутри контейнера. Их ставить не нужно и нельзя: NVIDIA Container Runtime
подмонтирует их с хоста. В `JETSON_CUDA_PACKAGES` должны быть только
dev-компоненты.

### `nvcc: command not found` в собранном образе

Проверьте симлинк `/usr/local/cuda` и `CUDA_HOME` в `platforms/*.env`: путь
включает минорную версию (`/usr/local/cuda-12.6`, `/usr/local/cuda-13.2`).

---

## Сборка пакетов

### `livox_ros_driver2` не собирается / colcon его не видит

В репозитории драйвера **нет `package.xml`** — есть `package_ROS1.xml` и
`package_ROS2.xml`. Штатно нужный подкладывает `./build.sh humble`, но он
запускает свой colcon на весь воркспейс, что ломает нашу схему. Это делает
pre-build скрипт `packages/prebuild/livox_ros2_stack.sh`.

Если драйвер собирается, но падает на отсутствующем `roscpp` — не переданы
`-DROS_EDITION=ROS2 -DHUMBLE_ROS=humble` (они в `PKG_CMAKE_ARGS` манифеста).

### `Could not find a package configuration file provided by "catkin"`

Собираемый пакет — ROS 1, а не ROS 2. Проверьте `<build_type>` в его
`package.xml` и наличие ветки с портом. Так, у `hku-mars/FAST-LIVO2` ветки
ROS 2 нет вообще — нужен форк сообщества.

### Исполняемый файл «не найден» при верификации, хотя сборка прошла

colcon кладёт бинарники в `install/lib/<имя ROS-пакета>/`, а не
`install/lib/<имя образа>/`. Для FAST-LIO2 это `fast_lio`, а образ называется
`fast_lio2`. Заполните `ROS_PACKAGE_NAME` в манифесте.

### Предупреждение «пакет заявлен для ROS: humble, а платформа использует jazzy»

Ровно то, что написано: порт проверен только на Humble, а платформа JetPack 7
использует Jazzy. Сборка не блокируется, но результат не гарантирован.
Заполняется полем `SUPPORTED_ROS_DISTROS`.

---

## Рантайм на устройстве

### `cudaGetDeviceCount failed: no CUDA-capable device is detected`

На Jetson — забыт `--runtime nvidia`. `--gpus all` там **не работает**, это
флаг для десктопного `nvidia-container-toolkit`:

```bash
sudo docker run --rm --runtime nvidia <image> ...
```

Проверьте, что рантайм зарегистрирован:

```bash
docker info | grep -i runtime
cat /etc/docker/daemon.json
```

### `CUDA driver version is insufficient for CUDA runtime version`

Версия CUDA в образе выше, чем драйвер на устройстве. Классический случай —
образ, собранный под JetPack 7 (CUDA 13.2), запущен на JetPack 6.2.2
(драйвер CUDA 12.6). Обратной совместимости здесь нет.

Проверьте соответствие тега образа устройству:

```bash
head -1 /etc/nv_tegra_release        # на устройстве
docker inspect <image> --format '{{index .Config.Labels "ru.armmeh.l4t-suite"}}'
```

### `no kernel image is available for execution on the device`

Device-код собран не под ту SM. Проверьте, что в образе:

```bash
docker run --rm --runtime nvidia <image> \
  cuobjdump --list-elf /opt/verify/install/lib/libcuda_verify_kernels.so
```

Для любого Orin там должно быть `sm_87`. Если видите другое — не совпадает
`CUDA_ARCHITECTURES` в описании платформы.

---

## CI

### `denied: permission_denied: write_package`

Settings → Actions → General → Workflow permissions → **Read and write**.

### `No space left on device` на раннере

Штатный раннер даёт около 14 ГБ свободного места, базовый образ с CUDA легко
занимает больше. Шаг «Освободить место на раннере» в workflow удаляет
предустановленные .NET, Android SDK и Haskell — это освобождает ~25 ГБ.
Если и этого мало, разнесите базовые образы по отдельным job'ам (уже сделано)
или используйте larger runners.

### Метки `ubuntu-24.04-arm` не работают

ARM64-раннеры GitHub доступны бесплатно **только в публичных репозиториях**.
В приватном workflow с такой меткой просто не стартует. Варианты: сделать
репозиторий публичным, купить larger runners или использовать self-hosted
раннер на Jetson.

### Кеш не срабатывает, каждая сборка идёт с нуля

Registry-кеш пишется только при `--push` (иначе некуда). Локальные сборки
кеш читают, но не обновляют. Проверьте, что `<image>-cache` существует в GHCR
и доступен на чтение.

---

## Диагностика

```bash
# что вообще внутри образа
docker run --rm -it <image> bash
nvcc --version
ros2 pkg list | wc -l
cuobjdump --list-elf /opt/verify/install/lib/libcuda_verify_kernels.so
cat /opt/overlay/SOURCE_REVISION

# какая ревизия пакета собрана, каким способом
docker inspect <image> --format '{{json .Config.Labels}}' | jq

# полный набор проверок
./scripts/verify-image.sh --image <image> --platform <id> --package <pkg>
```
