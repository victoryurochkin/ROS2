# 00 — Соответствие техническому заданию

Таблица «требование → где реализовано», чтобы проверку не приходилось вести
поиском по репозиторию.

## 3.1 Исследование и подготовка

| Требование | Реализация |
|---|---|
| Изучить архитектурные различия платформ | [01-architecture.md §1](01-architecture.md) — таблица различий и практические следствия |
| Инструменты кросс-компиляции (Buildx, QEMU, контейнеры NVIDIA) | [01-architecture.md §2, §4](01-architecture.md) — разбор трёх подходов, обоснование выбора |
| Тестовый пакет FAST-LIO2 / FAST-LIVO2 | `packages/fast_lio2.env` (ветка `ROS2` upstream), `packages/fast_livo2.env` (ROS 2-порт сообщества — у upstream ветки ROS 2 нет, см. ниже) |

## 3.2 Базовые Docker-образы

| Требование | Реализация |
|---|---|
| Три базовых образа (x86, AGX Orin, Orin Nano) | `platforms/*.env` + `docker/base/` (два Dockerfile на три образа) |
| ROS 2 Humble | Humble на x86 и AGX Orin; на JP 7 — Jazzy по умолчанию, Humble из исходников по флагу. Обоснование: [01-architecture.md §3](01-architecture.md#ros-2-на-jetpack-7) |
| CUDA Toolkit | 12.6 (JP 6.2.2), 13.2 (JP 7.2), 12.6 (x86) — dev-компоненты из репозитория JetPack |
| Системные зависимости | PCL, Eigen, OpenCV, Boost, glog, TBB — в каждом базовом образе |
| Публикация в публичный registry | `ghcr.io/victoryurochkin/ros2-cuda-base:<platform-id>`, workflow `base-images.yml` |

## 3.3 Универсальный шаблон сборки

| Требование | Реализация |
|---|---|
| Dockerfile-шаблон с аргументами | `docker/package/Dockerfile` |
| URL репозитория | `--build-arg PKG_REPO_URL` |
| Ветка | `--build-arg PKG_REF` |
| Целевая платформа | `--build-arg BASE_IMAGE` + `--platform` |
| Архитектура CUDA | `--build-arg CUDA_ARCHITECTURES` → `CMAKE_CUDA_ARCHITECTURES` для всех пакетов оверлея |
| Сборка с флагами поддержки CUDA | `PKG_CMAKE_ARGS`, `CMAKE_CUDA_COMPILER`, `CUDACXX`; проверяется через `cuobjdump` |

## 3.4 Кросс-платформенная сборка

| Требование | Реализация |
|---|---|
| Нативная сборка на ARM-раннере | hosted-раннеры `ubuntu-22.04-arm` / `ubuntu-24.04-arm`; self-hosted на Jetson — метки в `platforms/*.env`, инструкция в [02-deployment.md §6](02-deployment.md) |
| Кросс-компиляция через QEMU | `scripts/setup-qemu.sh` (версия QEMU зафиксирована), `docker buildx --platform linux/arm64` |
| Оба способа рядом | теги `<pkg>:<platform>-native` и `<pkg>:<platform>-cross`, сравнение в [05-verification.md](05-verification.md) |

## 3.5 Автоматизация CI/CD

| Требование | Реализация |
|---|---|
| Пайплайн в GitHub Actions | `.github/workflows/base-images.yml`, `.github/workflows/package-build.yml` |
| Триггер: push в main | `on.push.branches: [main]` |
| Триггер: создание тега | `on.push.tags: ['v*']`, плюс `release.published` для базовых образов |
| Триггер: ручной запуск | `workflow_dispatch` с параметрами (пакет, платформы, тип раннера, нативные ARM-сборки) |
| Матричная сборка 3×2 | job `plan` формирует матрицу из `platforms/*.env`; 3 платформы × {native, cross} |
| Кеширование слоёв | registry-кеш buildx `mode=max` + `--mount=type=cache` для apt и ccache. Почему не GHA-кеш — [01-architecture.md §6](01-architecture.md) |
| Тестирование собранных образов | шаг «Проверить образ» → `scripts/verify-image.sh`, отчёт в Job Summary и артефактах |

## 3.6 Документирование

| Требование | Реализация |
|---|---|
| Инструкция по развёртыванию пайплайна | [02-deployment.md](02-deployment.md) |
| Процесс добавления нового пакета | [03-add-package.md](03-add-package.md) — добавление = один `.env`-файл |
| Пример сборки открытого ROS2-пакета | FAST-LIO2 и FAST-LIVO2, готовые манифесты |

## 4. Ожидаемые результаты

| Результат | Где |
|---|---|
| Работающий CI/CD-пайплайн | `.github/workflows/` |
| Три базовых образа в реестре | `ghcr.io/victoryurochkin/ros2-cuda-base:{x86_64-cuda, jetson-agx-orin-jp62, jetson-orin-nano-jp7}` |
| Пример собранного образа | `ghcr.io/victoryurochkin/fast_lio2:<platform>-<mode>` |
| Подтверждение наличия CUDA | `tests/cuda_verify/` + `scripts/verify-image.sh`, методика в [05-verification.md](05-verification.md) |
| Документация и вспомогательные скрипты | `docs/`, `scripts/`, `Makefile` |

## Что сделано сверх ТЗ

* **Проверка device-кода через `cuobjdump`** — доказывает, что CUDA собрана под
  правильную SM-архитектуру, а не просто присутствует в образе. Работает без
  GPU, прямо на x86-раннере после кросс-сборки.
* **Один параметризованный Dockerfile на обе Jetson-платформы** вместо двух
  почти одинаковых.
* **Динамическая матрица CI** — добавление платформы не требует правки workflow.
* **Разбор конфликта «Humble на Ubuntu 24.04»** с тремя вариантами решения и
  переключателем между ними, вместо молчаливой подмены дистрибутива.

## Что осталось за рамками

* Реальный запуск на устройствах не выполнялся — Jetson AGX Orin и Orin Nano в
  наличии не было. Все рантайм-проверки на GPU реализованы и вызываются
  автоматически, но в отчётах на x86-раннере помечаются `SKIP`.
* **FAST-LIVO2 в upstream не поддерживает ROS 2.** Репозиторий
  `hku-mars/FAST-LIVO2` — чисто ROS 1 проект (Ubuntu 18.04–20.04,
  `catkin_make`, `roslaunch`), ветки ROS 2 в нём нет. Манифест указывает на
  порт сообщества `Robotic-Developer-Road/FAST-LIVO2` (ветка `humble`), он же
  тянет ament-версию `rpg_vikit`. У FAST-LIO2 ситуация лучше: ветка `ROS2` есть
  в upstream. Порт FAST-LIVO2 заявлен только под Humble, поэтому на платформе
  JetPack 7 (Jazzy) сборка не гарантирована — скрипт об этом предупреждает.
* FAST-LIO2 в upstream — CPU-алгоритм; «поддержка CUDA» означает готовность
  инфраструктуры, что доказано на `cuda_verify`. Подробно —
  [05-verification.md](05-verification.md), последний раздел.
* Multi-arch манифесты (один тег на несколько архитектур) сознательно не
  использовались: платформы различаются не только архитектурой, но и версиями
  CUDA и ROS, поэтому единый тег вводил бы в заблуждение.
