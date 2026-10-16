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
3. при первом запуске переносит старые `mods`/`config`/`defaultconfigs` в `.minecraft/_backup_<дата>`;
4. копирует миры, в которые играли последние 14 дней, в `.minecraft/_world_backups/<дата>` (хранит 3 копии);
5. запускает `packwiz-installer` по `https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/pack.toml` — докачивает изменения, удаляет убранное.

Повторный запуск = обновление. Всё, что попало в `main`, игроки получат при следующем запуске (с задержкой кэша GitHub до ~5 минут).

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
| Quark не грузится | NeoForge ниже 21.1.252 | Ставить NeoForge 21.1.262 (делает установщик) |
| Генерация мира падает / дыры при быстром полёте | Тяжёлая генерация (много модов на постройки) | Хосту 8–10 ГБ; заранее сгенерировать мир: `/chunky radius 2000`, `/chunky start` |
