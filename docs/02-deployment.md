# 02 — Развёртывание пайплайна

## 1. Требования

### Машина для локальной сборки

* Linux x86_64, ядро с поддержкой `binfmt_misc`
* Docker Engine ≥ 24 с плагином `buildx`
* ~60 ГБ свободного места (три базовых образа + кеш слоёв)
* `git`, `make`, `jq`
* для рантайм-тестов на x86: NVIDIA GPU + `nvidia-container-toolkit`

```bash
sudo apt install -y docker.io docker-buildx make jq git
sudo usermod -aG docker "$USER"   # перелогиниться
```

### GitHub

* публичный репозиторий (нужен для бесплатных ARM64-раннеров;
  в приватном метки `ubuntu-*-arm` не работают — потребуются larger runners)
* Settings → Actions → General → Workflow permissions: **Read and write**
  (иначе `GITHUB_TOKEN` не сможет пушить в ghcr.io)

## 2. Развёртывание за пять шагов

```bash
# 1. Форк/клон и настройка владельца образов
git clone ROS2 ros2-cuda-ci && cd ros2-cuda-ci

# 2. Регистрация QEMU (один раз на хост)
make qemu

# 3. Логин в реестр
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <username> --password-stdin

# 4. Базовые образы всех трёх платформ
export IMAGE_OWNER=<username-or-org>
./scripts/build-base.sh --all --push --no-load

# 5. Пример пакета
./scripts/build-package.sh --package fast_lio2 --platform x86_64-cuda --mode native --push
./scripts/build-package.sh --package fast_lio2 --platform jetson-agx-orin-jp62 --mode cross --push
./scripts/build-package.sh --package fast_lio2 --platform jetson-orin-nano-jp7 --mode cross --push
```

В CI то же самое делается автоматически: `push` в `main` запускает
`package-build.yml`, изменения в `docker/base/**` или `platforms/**` —
`base-images.yml`.

## 3. Публикация образов

Образы уходят в `ghcr.io/victoryurochkin/`:

```
ghcr.io/victoryurochkin/ros2-cuda-base:x86_64-cuda
ghcr.io/victoryurochkin/ros2-cuda-base:jetson-agx-orin-jp62
ghcr.io/victoryurochkin/ros2-cuda-base:jetson-orin-nano-jp7
ghcr.io/victoryurochkin/fast_lio2:x86_64-cuda-native
ghcr.io/victoryurochkin/fast_lio2:jetson-agx-orin-jp62-cross
ghcr.io/victoryurochkin/fast_lio2:jetson-agx-orin-jp62-native
ghcr.io/victoryurochkin/fast_lio2:jetson-orin-nano-jp7-cross
ghcr.io/victoryurochkin/fast_lio2:jetson-orin-nano-jp7-native
```

Плюс теги с коротким SHA коммита и кеш-репозитории `*-cache`.

После первой публикации пакеты в GHCR приватные. Сделать публичными:
GitHub → Packages → выбрать пакет → Package settings → Change visibility →
Public. Иначе `docker pull` с Jetson потребует логина.

## 4. Триггеры пайплайна

| Событие | Что запускается |
|---|---|
| `push` в `main` | сборка пакетов на всех платформах, обоими способами |
| `push` в `main`, затронувший `docker/base/**`, `platforms/**`, `tests/**` | пересборка базовых образов |
| `push` тега `v*` | полный прогон, образы получают тег версии |
| Release published | пересборка базовых образов |
| Ручной запуск (`workflow_dispatch`) | параметры: пакет, список платформ, включать ли нативные ARM-сборки, тип раннера |

Ручной запуск: Actions → package-build → Run workflow.

## 5. Запуск образов на целевых устройствах

### x86_64 с dGPU

```bash
docker run --rm -it --gpus all \
  ghcr.io/victoryurochkin/fast_lio2:x86_64-cuda-native \
  ros2 run cuda_verify cuda_info_node
```

### Jetson (любой)

На устройстве должен быть установлен `nvidia-container-runtime` — он ставится
вместе с JetPack. Обратите внимание на `--runtime nvidia`, а не `--gpus all`:

```bash
sudo docker run --rm -it --runtime nvidia --network host \
  ghcr.io/victoryurochkin/fast_lio2:jetson-agx-orin-jp62-cross \
  ros2 run cuda_verify cuda_info_node
```

Для работы с лидаром понадобится проброс сети и устройств:

```bash
sudo docker run --rm -it --runtime nvidia \
  --network host --ipc host --pid host \
  -v /dev:/dev --privileged \
  ghcr.io/victoryurochkin/fast_lio2:jetson-agx-orin-jp62-cross \
  ros2 launch fast_lio mapping.launch.py
```

## 6. Self-hosted раннер на Jetson

Нужен, если требуется нативная сборка на целевом железе и рантайм-тесты на
настоящем GPU в рамках CI.

```bash
# на Jetson
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.328.0/actions-runner-linux-arm64-2.328.0.tar.gz
tar xzf runner.tar.gz

./config.sh --url https://github.com/victoryurochkin/ROS2 --token <RUNNER_TOKEN> \
  --labels self-hosted,jetson,agx-orin,jp62 \
  --name jetson-agx-orin-01

sudo ./svc.sh install && sudo ./svc.sh start
```

Метки должны совпадать со значением `SELF_HOSTED_RUNNER` в соответствующем
`platforms/*.env`. После этого:

```
Actions → base-images → Run workflow → runner_kind: self-hosted-jetson
```

Практические оговорки для Jetson-раннера:

* держите Docker data-root на NVMe, а не на eMMC/SD — сборка съедает десятки
  гигабайт и убивает флеш-память записью;
* включите `MAXN`/максимальный power mode (`sudo nvpmodel -m 0 && sudo jetson_clocks`),
  иначе сборка идёт вдвое дольше;
* добавьте swap 8–16 ГБ: линковка PCL и колцоновская параллельная сборка на
  8-ГБ Orin Nano без свопа уходит в OOM.

## 7. Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `REGISTRY` | `ghcr.io` | реестр публикации |
| `IMAGE_OWNER` | владелец репозитория | префикс имён образов |
| `PARALLEL_WORKERS` | `nproc` (native), `2` (cross) | параллелизм colcon |
| `BUILDX_BUILDER` | `ros2-cuda-builder` | имя билдера |
| `CACHE_FROM` / `CACHE_TO` | `<image>-cache` | переопределение кеша |
| `BINFMT_IMAGE` | `tonistiigi/binfmt:qemu-v8.1.5` | версия QEMU |
