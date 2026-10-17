# Сторонние файлы в репозитории

- `mods/owonetfix-1.0.0.jar` — «owo Network Fix» (автор: Maxence / Illama), лицензия MIT
  (указана в `META-INF/neoforge.mods.toml` мода). Источник: https://www.curseforge.com/minecraft/mc-mods/owo-network-fix (file 9198890).
  Лежит в репозитории, потому что CurseForge не отдаёт этот файл сторонним установщикам.
  Исправляет вход в мир («Failed to encode packet custom_payload» / «[owo] Sided Packet Codec has not been unpacked»)
  у owo-lib 0.12.15.x на свежем NeoForge 21.1.

- `kubejs/assets/computercraft/textures/gui/term_font.png` — шрифт терминала CC: Tweaked
  (© Daniel Ratcliffe и участники CC: Tweaked, https://github.com/cc-tweaked/CC-Tweaked; условия — как у исходного
  файла из jar мода) с дорисованной кириллицей в слотах CP1251. Генерируется из оригинала скриптом
  `tools/gen/gen_font.py`; изменены только 67 глифов (А..я, Ё, ё, №).
