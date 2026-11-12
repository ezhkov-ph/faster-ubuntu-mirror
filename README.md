# Faster Ubuntu Mirror — быстрый выбор зеркала Ubuntu / fast APT mirror selector

[![CI](https://github.com/ezhkov-ph/faster-ubuntu-mirror/actions/workflows/ci.yml/badge.svg)](https://github.com/ezhkov-ph/faster-ubuntu-mirror/actions/workflows/ci.yml)

Безопасный Bash-скрипт для поиска быстрых официальных зеркал Ubuntu и смены URI в источниках APT (`sources.list` и `ubuntu.sources`). Подходит для Ubuntu Server, Desktop, VPS, Docker-образов и медленных или перегруженных репозиториев.

**Fast Ubuntu APT mirror selector.** A safe Bash utility that discovers responsive official Ubuntu package mirrors, benchmarks the active release metadata, and updates `sources.list` or Deb822 `ubuntu.sources` with automatic backup and rollback.

## Что делает

- получает актуальный список зарегистрированных зеркал из официального сервиса Ubuntu;
- выбирает пакет из индекса активного релиза и проверяет у каждого зеркала Range-загрузку его данных;
- ранжирует доступные зеркала по скорости загрузки;
- по умолчанию предлагает выбор интерактивно;
- перед применением всегда создаёт резервную копию;
- проверяет результат через `apt-get update` и автоматически восстанавливает предыдущий файл при ошибке;
- поддерживает современный Deb822-файл `ubuntu.sources` и старый `sources.list`.

Официальный индекс зеркал зависит от IP клиента и обновляется Canonical регулярно: <https://mirrors.ubuntu.com/mirrors.txt>.

## English — Ubuntu mirror selector

Faster Ubuntu Mirror helps Ubuntu users choose a nearby, fast and reachable **APT repository mirror**. It obtains registered mirrors from Canonical’s mirror index, selects a package from the active release, downloads a byte range from that package, ranks mirrors by throughput, and safely updates the system APT source.

It supports both the traditional `sources.list` format and Ubuntu’s modern Deb822 `ubuntu.sources` format. Every real change is backed up and verified with `apt-get update`; a failed verification restores the previous source file automatically.

Common search terms: **Ubuntu fastest mirror**, **Ubuntu APT mirror**, **change Ubuntu repository mirror**, **sources.list mirror**, **ubuntu.sources mirror**, **Ubuntu package download speed**, **Ubuntu mirror benchmark**, **зеркало Ubuntu**, **быстрое зеркало APT**, **смена репозиториев Ubuntu**.

## Требования

- Ubuntu с Bash;
- `curl`, `awk`, `sort`, `grep`, `diff`, `mktemp` — обычно уже есть в системе;
- `sudo` только для фактического изменения APT-источников.

Проверить сценарий без каких-либо изменений можно без `sudo`:

```bash
./run.sh --dry-run
```

## Установка

```bash
git clone https://github.com/ezhkov-ph/faster-ubuntu-mirror.git
cd faster-ubuntu-mirror
chmod +x run.sh
```

Либо скачайте только скрипт:

```bash
curl -fLO https://raw.githubusercontent.com/ezhkov-ph/faster-ubuntu-mirror/main/run.sh
chmod +x run.sh
```

## Использование

```bash
# Посмотреть будущие изменения, ничего не записывая
./run.sh --dry-run

# Интерактивно выбрать одно зеркало из Германии и Франции
sudo ./run.sh -c DE FR

# Автоматически применить самое быстрое зеркало
sudo ./run.sh --auto

# Выбрать до двух зеркал. В Deb822 они попадут в поле URIs в порядке скорости.
sudo ./run.sh -n 2 -c JP US

# Увеличить объём проверяемых данных до 500 KiB
sudo ./run.sh --size 500 --auto

# Принудительно обновить старый /etc/apt/sources.list
sudo ./run.sh --legacy
```

`--auto` (также `--auto-select`) отключает только интерактивный выбор. Он не отключает backup и проверку `apt-get update`. Флаг `--no-apt-update` оставлен для контролируемых окружений и CI; в обычной системе его использовать не следует.

## Как изменяются источники

На современных установках Ubuntu скрипт выбирает `/etc/apt/sources.list.d/ubuntu.sources` и меняет только поля `URIs:`, сохраняя suites, components и `Signed-By`. Такой формат соответствует текущей рекомендации Ubuntu для `ubuntu.sources`.

На старых установках меняются только активные строки `deb`/`deb-src`, содержащие официальный URI `*.ubuntu.com/ubuntu`; PPAs и сторонние репозитории не затрагиваются. В старом однострочном формате APT на запись приходится один URI, поэтому при `-n > 1` применяется только самое быстрое зеркало.

Файлы резервных копий создаются рядом с исходным файлом, например:

```text
/etc/apt/sources.list.d/ubuntu.sources.faster-ubuntu-mirror.20260721T120000Z.bak
```

Чтобы откатиться вручную, скопируйте backup обратно и выполните `sudo apt-get update`.

## Разработка

```bash
bash -n run.sh
bash tests/test_transform.sh
```

CI запускает эти проверки и ShellCheck для каждого push и pull request.

Правила для pull request и сообщений об ошибках: [CONTRIBUTING.md](CONTRIBUTING.md). Уязвимости, связанные с заменой APT-источников, пожалуйста, сообщайте по [security policy](SECURITY.md), а не через публичный issue.

## Лицензия

[MIT](LICENSE).
