# Как устроена и как ведётся сборка

> Обновлено: 2026-10-17. Без сюжетных подробностей — репозиторий публичный.

## Состав репозитория
| Путь | Что |
|---|---|
| `pack.toml`, `index.toml` | Манифест [packwiz](https://packwiz.infra.link/): Minecraft 1.21.1, NeoForge 21.1.262 |
| `mods/*.pw.toml` | Ссылки на моды (Modrinth/CurseForge) с хэшами. Сами jar в репозитории не лежат, кроме исключений из `THIRD_PARTY.md` |
| `resourcepacks/`, `shaderpacks/` | Пакеты ресурсов и шейдеры (ссылки) |
| `config/` | Настройки модов, которые раздаются игрокам (перезаписываются при обновлении) |
| `kubejs/` | Скрипты KubeJS: свои предметы, рецепты, лут, квестовые связки; `kubejs/data/computercraft/lua/rom/` — программы для компьютеров CC: Tweaked (ИИ-компаньон, КПК) |
| `installer/` | Установщики для игроков (в сам пак не входят — `.packwizignore`) |
| `docs/` | Эта документация (в пак не входит) |

## Как игроки получают сборку
`installer/TechnoMagic-Windows.bat` скачивает свежий `installer/install.ps1` с ветки `main` и запускает его; на macOS — `installer/TechnoMagic-Mac.command`. Установщик:
1. находит Java 21 (или скачивает Temurin);
2. ставит NeoForge 21.1.262, если его нет;
3. при первой установке переносит старые `mods`/`config`/`defaultconfigs` в `.minecraft/_backup_<дата>`. Первая установка = нет ни метки `.minecraft/technomagic-installed.txt`, ни `packwiz.json` (второе — для тех, кто ставил до появления метки). Метка пишется сразу после этого шага, так что удаление или порча `packwiz.json` больше не приводит к переносу модов;
4. копирует миры, в которые играли последние 14 дней, в `.minecraft/_world_backups/<дата>` (хранит 3 копии);
5. в режиме смены графики (см. ниже) сбрасывает сохранённый выбор необязательных модов;
6. запускает `packwiz-installer` по `https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/pack.toml` — докачивает изменения, удаляет убранное;
7. предупреждает, если включён EMF без ETF (игра не запустится) или Fresh Animations без EMF и ETF.

Повторный запуск = обновление. Всё, что попало в `main`, игроки получат при следующем запуске (с задержкой кэша GitHub до ~5 минут).

## Необязательные моды («лёгкий режим»)
Клиентские «красивости» помечены в `.pw.toml` блоком
```toml
[option]
optional = true
default = true              # по умолчанию включено (для мощных ПК); без этой строки было бы выключено
description = "Что даёт. Нагрузка: …"
```
При первой установке (и когда в сборке появляется новая опция) `packwiz-installer` показывает окно «Optional mods» с галочками и описанием справа. Всё включено по умолчанию; для слабых машин (Мак M2, 8 ГБ) галочки снимают.

| Опция | Файл | Заметки |
|---|---|---|
| Iris Shaders | `mods/iris.pw.toml` | загрузчик шейдеров |
| Complementary Reimagined, MakeUp Ultra Fast | `shaderpacks/*.pw.toml` | без Iris бесполезны (вреда нет) |
| Better Clouds | `mods/better-clouds.pw.toml` | YACL остаётся: нужен Critters and Companions |
| ETF, EMF, Fresh Animations | `mods/entitytexturefeatures`, `mods/entity-model-features`, `resourcepacks/fresh-animations` | связка: EMF без ETF — игра не запустится; FA без обоих не работает |
| Better Leaves | `resourcepacks/better-leaves.pw.toml` | |
| Wavey Capes | `mods/wavey-capes.pw.toml` | |
| LambDynamicLights | `mods/lambdynamiclights.pw.toml` | Naturalist ссылается на его API только как optional |
| Sound Physics Remastered | `mods/sound-physics-remastered.pw.toml` | side = both, сетевых каналов нет |
| AmbientSounds | `mods/ambientsounds.pw.toml` | ~85 МБ |

Пакеты ресурсов и шейдеры игрок включает в игре сам (`options.txt` сборка не раздаёт), поэтому их отсутствие ничего не ломает.

**Что нельзя делать необязательным.** Моды производительности (Sodium, Sodium Extra, Reese's Sodium Options, ImmediatelyFast, Entity Culling, ModernFix, FerriteCore, C2ME, ScalableLux, Lithium, Clumps и т.п.), всё, от чего зависят обязательные моды, всё, что регистрирует сетевые каналы, которые сервер шлёт каждому игроку, и **всё, что добавляет записи в синхронизируемые реестры** (предметы, блоки, сущности, **типы частиц**, звуки и т.п.): сервер сверяет реестры с клиентом и не пустит игрока без них («Сервер отправил реестры с неизвестными ключами»). Пример — **Particle Rain** (регистрирует `particlerain:*` частицы) — поэтому он обязательный. Пример — **CreativeCore** (нужен только AmbientSounds, но остаётся обязательным): при входе игрока сервер (в том числе мир хоста, открытый по сети) шлёт ему пакет синхронизации настроек CreativeCore, а NeoForge 21.1 бросает `UnsupportedOperationException`, если у клиента нет этого канала, — без CreativeCore в мир к хосту не зайти. Хост обычно играет со всеми опциями, поэтому у «лёгкого» клиента не должно быть недостающих каналов.

**Перед добавлением новой опции:**
1. `depcheck.py client` для двух крайних наборов — все опции включены и все выключены (папка с симлинками без jar опциональных модов): никаких `MISSING`.
2. Проверить, что мод не регистрирует записи реестров (в jar нет `assets/*/particles/*.json`, `DeferredRegister`/`Registries.*` в классах) и не регистрирует сетевые payload'ы (поиск `PayloadRegistrar`/`RegisterPayloadHandlersEvent` в классах jar) или что сервер не шлёт их всем подряд.
3. Если одна опция требует другую — написать это в обеих `description` и, если без пары игра не запустится, добавить проверку в конец обоих установщиков (как для EMF/ETF).
4. `packwiz refresh`.

**Где хранится выбор.** `packwiz-installer` пишет состояние в `.minecraft/packwiz.json` (gson, одной строкой): `packFileHash`, `indexFileHash`, `cachedSide` и `cachedFiles` — словарь «путь `.pw.toml` → `{hash, linkedFileHash, cachedLocation, isOptional, optionValue, onlyOtherSide}`». Выбор игрока — `optionValue` у записей с `isOptional: true`. Окно с галочками показывается само, только если опция «новая» (у записи нет `isOptional`); при каждом обычном запуске в окне прогресса есть кнопка «Optional mods...» с 10-секундным отсчётом «Continue» — по ней открывается текущий выбор.

**Режим смены графики** — `TechnoMagic-Windows-Graphics.bat` (запускает `install.ps1 -Graphics`) или `bash TechnoMagic-Mac.command --graphics`. Перед запуском `packwiz-installer` он у записей с `isOptional: true` удаляет `isOptional` и `hash`, а сверху — `packFileHash`/`indexFileHash` (иначе при неизменной сборке список файлов не перебирается). `cachedLocation` и `optionValue` не трогаются: `packwiz-installer` перечитывает метаданные, видит опции как новые и показывает окно (со значениями по умолчанию — все включены), затем сверяет файлы на диске по хэшу — выключенное удаляется, включённое не качается заново. Если `packwiz.json` не читается — он переименовывается в `packwiz.json.bad` (тогда `packwiz-installer` строит состояние заново, сверяя файлы по хэшам; моды в резервную папку не уезжают благодаря метке). На Windows правка делается через `System.Web.Extensions` (`JavaScriptSerializer`, запись UTF-8 без BOM — с BOM gson не прочитает), на Маке — через `osascript -l JavaScript`.

## Работа с модами
```bash
packwiz modrinth add <slug>      # или: packwiz curseforge add <slug>
packwiz remove <name>
packwiz refresh                  # после любых ручных правок файлов
```
- После `curseforge add` проверять дубли: CF-зависимости дублируют уже стоящие Modrinth-моды и могут перезаписать одноимённый `.pw.toml`.
- Если CurseForge не отдаёт файл сторонним установщикам (`mode = "metadata:curseforge"` → у игроков «Failed file downloads»), а лицензия разрешает — класть jar в `mods/` и описывать в `THIRD_PARTY.md`.
- Клиентские зависимости тестовый сервер не проверяет — нужна статическая проверка (`depcheck.py` из рабочей папки сопровождающего).

## Правила, чтобы не ломать миры игроков
- Безопасно: настройки, рецепты, квесты (без смены ID), добавление модов, программы компьютеров.
- Осторожно: удаление модов с блоками (блоки исчезнут — предупреждать заранее), изменения генерации (действуют только на новые чанки).
- Серверные настройки уже созданного мира хранятся в `saves/<мир>/serverconfig/` и обновлением не меняются.

## Известные проблемы и их решения
| Симптом | Причина | Решение |
|---|---|---|
| `Failed to encode packet 'clientbound/minecraft:custom_payload'` при входе в мир | owo-lib 0.12.15 на свежем NeoForge 21.1 (Accessories из Aether) | `mods/owonetfix-1.0.0.jar` (MIT) |
| `reeses_sodium_options is incompatible with sodiumoptionsapi` | Sodium Dynamic Lights тянет Sodium Options API | Динамический свет — LambDynamicLights |
| Вступление про кораблекрушение и телепорт при первом входе | «Судьба» MCA Reborn | Выключено в `config/mca.json` |
| «Сервер отправил реестры с неизвестными ключами» (список предметов `neovitae:*`) | Neo Vitae сам дописывает `config/neovitae/materials.json` под найденные руды; у хоста и клиента разные списки | Полный список лежит в `config/neovitae/materials.json` пака; при добавлении модов с рудами — обновить его с ПК хоста |
| Quark не грузится | NeoForge ниже 21.1.252 | Ставить NeoForge 21.1.262 (делает установщик) |
| `Mod entity_model_features requires entity_texture_features` при запуске | В окне необязательных модов включён EMF, а ETF выключен | Режим смены графики: включить оба или выключить оба (установщик предупреждает) |
| Игрока с «лёгким» набором не пускает в мир хоста | Выключен мод, чей сетевой канал сервер шлёт всем (пример — CreativeCore) | Такой мод не делать необязательным (см. «Необязательные моды») |
| Генерация мира падает / дыры при быстром полёте | Тяжёлая генерация (много модов на постройки) | Хосту 8–10 ГБ; заранее сгенерировать мир: `/chunky radius 2000`, `/chunky start` |
