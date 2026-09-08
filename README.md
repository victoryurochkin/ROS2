# Кросс-платформенная сборка Docker-образов для ROS 2 + CUDA

Система автоматической сборки Docker-образов ROS 2-пакетов с поддержкой CUDA
под три платформы: x86_64 с дискретным NVIDIA GPU, Jetson AGX Orin (JetPack
6.2.2) и Jetson Orin Nano (JetPack 7). Сборка выполняется как нативно, так и
кросс-платформенно на x86-хосте через QEMU. Результат публикуется в GitHub
Container Registry.

## Что внутри

| Каталог | Назначение |
|---|---|
| `platforms/*.env` | Описания целевых платформ — единственное место, где живут версии JetPack, CUDA, ROS и SM-архитектуры |
| `packages/*.env` | Манифесты собираемых ROS-пакетов. Добавить пакет = добавить один файл |
| `docker/base/` | Два Dockerfile на три базовых образа (x86 и параметризованный Jetson) |
| `docker/package/Dockerfile` | Универсальный шаблон сборки произвольного ROS 2-пакета |
| `tests/cuda_verify/` | ROS 2-пакет с CUDA-ядром: доказывает работоспособность CUDA в образе |
| `scripts/` | Сборка, QEMU, верификация. CI вызывает те же скрипты, что и человек |
| `.github/workflows/` | Пайплайн: матрица 3 платформы × 2 типа сборки, кеш, тесты |
| `docs/` | Архитектура, развёртывание, добавление пакета, отладка, результаты |

## Целевые платформы

| Платформа | JetPack / L4T | ОС | CUDA | ROS 2 | SM |
|---|---|---|---|---|---|
| `x86_64-cuda` | — | Ubuntu 22.04 | 12.6 | Humble | 75;80;86;89;90 |
| `jetson-agx-orin-jp62` | JP 6.2.2 / R36.5.0 | Ubuntu 22.04 | 12.6 | Humble | 87 |
| `jetson-orin-nano-jp7` | JP 7.2 / R39.2 | Ubuntu 24.04 | 13.2 | Jazzy¹ | 87 |

¹ На rootfs 24.04 бинарных пакетов Humble не существует. По умолчанию ставится
Jazzy; сборка Humble из исходников включается одним аргументом. Обоснование —
[docs/01-architecture.md](docs/01-architecture.md#ros-2-на-jetpack-7).

## Быстрый старт

```bash
git clone <repo> && cd ros2-cuda-ci

# один раз: регистрация QEMU для кросс-сборки arm64 на x86
make qemu

# базовый образ под AGX Orin, кросс-сборка на x86
make base PLATFORM=jetson-agx-orin-jp62

# образ FAST-LIO2 поверх него
make package PACKAGE=fast_lio2 PLATFORM=jetson-agx-orin-jp62 MODE=cross

# проверка: nvcc, ROS, наличие device-кода под sm_87, запуск на GPU
make verify PACKAGE=fast_lio2 PLATFORM=jetson-agx-orin-jp62 MODE=cross
```

`make help` покажет остальные команды.

## Как это устроено

```
platforms/<id>.env ─┐
                    ├─> scripts/build-base.sh ──> ros2-cuda-base:<id>
docker/base/*       ─┘                                     │
                                                           ▼
packages/<pkg>.env ─┐                            docker/package/Dockerfile
packages/<pkg>.repos├─> scripts/build-package.sh ──> <pkg>:<id>-{native|cross}
packages/prebuild/  ┘                                      │
                                                           ▼
                                           scripts/verify-image.sh ──> отчёт
```

Ключевое свойство: **ни один Dockerfile не знает ни про конкретную платформу,
ни про конкретный пакет.** Всё различие вынесено в `.env`-файлы, которые
одинаково читаются и bash-скриптами, и матрицей GitHub Actions. Добавление
платформы или пакета не требует правки Dockerfile и workflow.

## Подтверждение CUDA в образах

Проверка не ограничивается `nvcc --version`. В каждый базовый образ собирается
пакет `cuda_verify` с настоящим CUDA-ядром, после чего:

* `cuobjdump --list-elf` показывает, что в `.so` лежит device-код **ровно под
  целевую SM-архитектуру** — эта проверка работает на x86-раннере без GPU сразу
  после кросс-сборки;
* `ldd` подтверждает линковку с `libcudart`;
* на машине с GPU (или на самом Jetson) `cuda_smoke` выполняет вычисление на
  устройстве и сверяет результат, а нода `cuda_info_node` публикует параметры
  GPU в топик ROS.

Подробности и примеры вывода — [docs/05-verification.md](docs/05-verification.md).

## Документация

* [00 — Соответствие ТЗ (карта: требование → реализация)](docs/00-checklist.md)
* [01 — Архитектура и обоснование решений](docs/01-architecture.md)
* [02 — Развёртывание пайплайна](docs/02-deployment.md)
* [03 — Добавление нового пакета](docs/03-add-package.md)
* [04 — Отладка и типовые проблемы](docs/04-troubleshooting.md)
* [05 — Верификация и результаты](docs/05-verification.md)
