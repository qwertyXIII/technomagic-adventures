# TechnoMagic Adventures

Сборка Minecraft **1.21.1 / NeoForge 21.1.262**: техника, магия, приключения, космос.

👉 **[Как начать играть](docs/start.md)** — установка, новый мир, генерация мира заранее, включение бортового ИИ, что делать, если что-то не так.
👉 **[Что нового](docs/devs/changelog.md)** — изменения по версиям.

## Установка и обновление

**Windows:** скачайте [TechnoMagic-Windows.bat](https://github.com/qwertyXIII/technomagic-adventures/raw/main/installer/TechnoMagic-Windows.bat) и запустите двойным кликом.

**macOS:** скачайте [TechnoMagic-Mac.command](https://github.com/qwertyXIII/technomagic-adventures/raw/main/installer/TechnoMagic-Mac.command), затем в Терминале: `bash ~/Downloads/TechnoMagic-Mac.command`.

Установщик ставит NeoForge, убирает старые моды в резервную папку и скачивает сборку. Повторный запуск — обновление.

После установки выберите в лаунчере версию `neoforge-21.1.262` и выделите игре 8 ГБ памяти (на Маке с 8 ГБ — 5 ГБ).

## Лёгкий режим (слабый компьютер, Мак с 8 ГБ)

При первой установке откроется окно **Optional mods** со списком «красивостей»: шейдеры, объёмные облака, дождь из частиц, анимации мобов, пышная листва, динамический свет, реалистичный звук, звуки окружения. Нажмите на пункт — справа появится описание: что он даёт и насколько грузит компьютер. По умолчанию включено всё (для мощных ПК).

Те, у кого сборка уже стоит, увидят это окно один раз при ближайшем обновлении — на мощном ПК достаточно нажать OK.

**На Маке и слабых компьютерах снимите все галочки и нажмите OK** — игра будет заметно легче. Моды оптимизации (Sodium и др.) остаются всегда.

- EMF, ETF и Fresh Animations — одна связка: включайте или выключайте все три вместе (EMF без ETF игра не запустится, установщик об этом предупредит).
- Шейдеры (Complementary, MakeUp) работают только вместе с Iris Shaders и включаются в самой игре, в настройках графики. Пакеты ресурсов (Fresh Animations, Better Leaves) — в игре: Настройки → Пакеты ресурсов.

**Поменять выбор позже:**
- **Windows:** скачайте и запустите [TechnoMagic-Windows-Graphics.bat](https://github.com/qwertyXIII/technomagic-adventures/raw/main/installer/TechnoMagic-Windows-Graphics.bat).
- **macOS:** в Терминале: `bash ~/Downloads/TechnoMagic-Mac.command --graphics` (скрипт должен быть свежим — при необходимости скачайте заново по ссылке выше).

Окно с галочками откроется снова, все пункты будут включены — снимите лишние и нажмите OK. Выключенное удалится, включённое докачается; миры и настройки не затрагиваются. Ещё вариант: при обычном запуске установщика в окне загрузки 10 секунд доступна кнопка **Optional mods...** — она открывает текущий выбор.

## Для разработки

Сборка ведётся в [packwiz](https://packwiz.infra.link/): `packwiz modrinth add <мод>`, `packwiz refresh`. Как устроена сборка — [docs/maintaining.md](docs/maintaining.md), решения — [docs/devs/decisions](docs/devs/decisions/), планы — [docs/devs/roadmap.md](docs/devs/roadmap.md).
