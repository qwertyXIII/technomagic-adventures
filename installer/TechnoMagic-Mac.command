#!/bin/bash
# Установка и обновление сборки TechnoMagic Adventures (macOS).
# Запускать можно сколько угодно раз: повторный запуск = обновление сборки.
# --graphics: заново показать окно выбора необязательных «красивостей» (шейдеры, анимации мобов,
# звук и т.п.) — лёгкий режим для слабых машин. Сбрасывает только сохранённый выбор.
set -u

GRAPHICS=0
for arg in "$@"; do
  case "$arg" in
    --graphics|graphics) GRAPHICS=1 ;;
  esac
done

PACK_URL="https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/pack.toml"
NEOFORGE_VERSION="21.1.262"
MC="$HOME/Library/Application Support/minecraft"
TOOLS="$HOME/Library/Application Support/TechnoMagic"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mОШИБКА: %s\033[0m\n' "$1"; exit 1; }

# Сброс сохранённого выбора необязательных модов, чтобы packwiz-installer снова показал окно с галочками.
# packwiz-installer хранит выбор в packwiz.json: cachedFiles.<файл>.isOptional / optionValue.
# Если у записи нет isOptional и не совпадает hash, он перечитывает метаданные, видит опцию как «новую»
# и показывает окно (со значениями по умолчанию). packFileHash/indexFileHash убираем, иначе при
# неизменной сборке он вообще не дойдёт до списка файлов. Остальное (где лежат файлы) не трогаем —
# так выключенные пункты удаляются с диска, а включённые не скачиваются заново.
reset_optional_choice_js() {
  osascript -l JavaScript - "$1" <<'JS'
function run(argv) {
  ObjC.import('Foundation');
  var path = argv[0];
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (text.isNil()) throw new Error('cannot read ' + path);
  var data = JSON.parse(text.js);
  var files = data.cachedFiles || {};
  var count = 0;
  Object.keys(files).forEach(function (k) {
    var f = files[k];
    if (f && f.isOptional === true) { delete f.isOptional; delete f.hash; count++; }
  });
  delete data.packFileHash;
  delete data.indexFileHash;
  if (!$(JSON.stringify(data)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null))
    throw new Error('cannot write ' + path);
  return String(count);
}
JS
}

reset_optional_choice() {
  [ -f "$1" ] || return 0
  local n
  if n=$(reset_optional_choice_js "$1" 2>/dev/null); then
    echo "Сброшен сохранённый выбор (пунктов: $n)"
  else
    # Повреждённый файл: убираем в сторону, packwiz-installer соберёт его заново
    # (сверит уже скачанные файлы по хэшам, повторно качать всё не будет).
    mv -f "$1" "$1.bad"
    echo "Файл состояния packwiz.json не прочитался — переименован в packwiz.json.bad"
  fi
}

is_java21() { [ -x "$1" ] && "$1" -version 2>&1 | grep -qE 'version "(2[1-9]|[3-9][0-9])'; }

find_java() {
  local c
  for c in "$TOOLS/jre/Contents/Home/bin/java" \
           /opt/homebrew/opt/openjdk@21/bin/java \
           "$(/usr/libexec/java_home -v 21 2>/dev/null)/bin/java"; do
    if is_java21 "$c"; then echo "$c"; return; fi
  done
  step "Java 21 не найдена — скачиваю (Eclipse Temurin)" >&2
  local arch; arch=$([ "$(uname -m)" = "arm64" ] && echo aarch64 || echo x64)
  mkdir -p "$TOOLS"
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/mac/$arch/jre/hotspot/normal/eclipse" -o "$TOOLS/jre.tar.gz" || fail "не удалось скачать Java"
  rm -rf "$TOOLS/jre" "$TOOLS/jre-unpack" && mkdir -p "$TOOLS/jre-unpack"
  tar -xzf "$TOOLS/jre.tar.gz" -C "$TOOLS/jre-unpack" && mv "$TOOLS/jre-unpack/"* "$TOOLS/jre"
  rm -rf "$TOOLS/jre-unpack" "$TOOLS/jre.tar.gz"
  is_java21 "$TOOLS/jre/Contents/Home/bin/java" || fail "не удалось подготовить Java 21"
  echo "$TOOLS/jre/Contents/Home/bin/java"
}

printf '\033[32mTechnoMagic Adventures — установка / обновление\033[0m\n'
echo "Папка игры: $MC"
pgrep -f 'net.minecraft.client.main.Main|neoforge.*client' >/dev/null && fail "игра сейчас запущена. Закройте Minecraft и запустите установщик снова."

mkdir -p "$MC"
JAVA=$(find_java) || exit 1
echo "Java: $JAVA"

# 1. NeoForge
if [ -d "$MC/versions/neoforge-$NEOFORGE_VERSION" ]; then
  step "NeoForge $NEOFORGE_VERSION уже установлен"
else
  step "Устанавливаю NeoForge $NEOFORGE_VERSION"
  [ -f "$MC/launcher_profiles.json" ] || echo '{"profiles":{}}' > "$MC/launcher_profiles.json"
  INST="${TMPDIR:-/tmp}/neoforge-$NEOFORGE_VERSION-installer.jar"
  curl -fsSL "https://maven.neoforged.net/releases/net/neoforged/neoforge/$NEOFORGE_VERSION/neoforge-$NEOFORGE_VERSION-installer.jar" -o "$INST" || fail "не удалось скачать NeoForge"
  (cd "${TMPDIR:-/tmp}" && "$JAVA" -jar "$INST" --installClient "$MC" | tail -2)
  [ -d "$MC/versions/neoforge-$NEOFORGE_VERSION" ] || fail "NeoForge не установился"
fi

# 2. Первый запуск: старые моды и настройки — в резервную папку (ничего не удаляется).
# Признак установки — свой файл-метка; packwiz.json (состояние packwiz-installer) тоже считается
# признаком, чтобы не трогать тех, кто ставил сборку до появления метки.
MARKER="$MC/technomagic-installed.txt"
MANIFEST="$MC/packwiz.json"
if [ ! -f "$MARKER" ] && [ ! -f "$MANIFEST" ]; then
  BAK="$MC/_backup_$(date +%Y-%m-%d_%H%M)"
  for d in mods config defaultconfigs; do
    if [ -e "$MC/$d" ]; then
      { mkdir -p "$BAK" && mv "$MC/$d" "$BAK/$d"; } || fail "не удалось перенести $d в резервную папку"
      echo "Перенесено в резервную папку: $d"
    fi
  done
fi
[ -f "$MARKER" ] || echo "TechnoMagic Adventures installer marker ($(date '+%Y-%m-%d %H:%M')): the pack is installed here, old mods/config are moved to a backup only on the very first install." > "$MARKER"

# 3. Копия миров перед обновлением: только миры, в которые играли последние 14 дней; храним 3 последние копии
RECENT=$(find "$MC/saves" -mindepth 2 -maxdepth 2 -name level.dat -mtime -14 2>/dev/null)
if [ -n "$RECENT" ]; then
  DEST="$MC/_world_backups/$(date +%Y-%m-%d_%H%M)"
  step "Сохраняю копию миров перед обновлением: $DEST"
  mkdir -p "$DEST"
  while IFS= read -r lvl; do
    W=$(dirname "$lvl")
    cp -R "$W" "$DEST/" || fail "не удалось скопировать мир $(basename "$W"). Обновление отменено, мир не тронут."
    echo "  $(basename "$W")"
  done <<< "$RECENT"
  ls -1d "$MC/_world_backups/"*/ 2>/dev/null | sort -r | tail -n +4 | while IFS= read -r old; do rm -rf "$old"; done
fi

# 4. Моды, настройки, пакеты ресурсов, шейдеры
if [ "$GRAPHICS" = 1 ]; then
  step "Изменение набора графики: сейчас откроется окно с галочками"
  echo "Все пункты будут включены (как для мощного ПК). Для лёгкого режима снимите галочки и нажмите OK."
  reset_optional_choice "$MANIFEST"
fi
step "Скачиваю и обновляю сборку (в первый раз ~1 ГБ, откроется окно с прогрессом)"
BOOT="$MC/packwiz-installer-bootstrap.jar"
[ -f "$BOOT" ] || curl -fsSL "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar" -o "$BOOT" || fail "не удалось скачать packwiz"
(cd "$MC" && "$JAVA" -jar "$BOOT" "$PACK_URL") || fail "скачивание сборки завершилось с ошибкой"

# Связка EMF + ETF + Fresh Animations: packwiz не умеет зависимости между галочками — проверяем сами
has() { compgen -G "$1" >/dev/null; }
if has "$MC/mods/entity_model_features-*.jar" && ! has "$MC/mods/entity_texture_features-*.jar"; then
  printf '\n\033[33mВНИМАНИЕ: включён EMF без ETF — игра не запустится. Запустите установщик с --graphics и включите оба (или выключите оба).\033[0m\n'
elif has "$MC/resourcepacks/FreshAnimations*" && ! { has "$MC/mods/entity_model_features-*.jar" && has "$MC/mods/entity_texture_features-*.jar"; }; then
  printf '\n\033[33mFresh Animations без EMF и ETF работать не будет (игра запустится). Поменять выбор: установщик с --graphics.\033[0m\n'
fi

printf '\n\033[32mГотово!\033[0m\n'
echo "В лаунчере выберите версию: neoforge-$NEOFORGE_VERSION"
echo "Выделите игре памяти: на Маке с 8 ГБ — 5 ГБ, на компьютере с 16 ГБ и больше — 8 ГБ"
echo "Чтобы обновить сборку — просто запустите этот установщик ещё раз."
echo "Чтобы поменять набор графики (лёгкий режим для Мака) — запустите его с --graphics:"
echo "  bash ~/Downloads/TechnoMagic-Mac.command --graphics"
