#!/bin/bash
# Установка и обновление сборки TechnoMagic Adventures (macOS).
# Запускать можно сколько угодно раз: повторный запуск = обновление сборки.
set -u

PACK_URL="https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/pack.toml"
NEOFORGE_VERSION="21.1.262"
MC="$HOME/Library/Application Support/minecraft"
TOOLS="$HOME/Library/Application Support/TechnoMagic"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mОШИБКА: %s\033[0m\n' "$1"; exit 1; }

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

# 2. Первый запуск: старые моды и настройки — в резервную папку (ничего не удаляется)
if [ ! -f "$MC/packwiz.json" ]; then
  BAK="$MC/_backup_$(date +%Y-%m-%d_%H%M)"
  for d in mods config defaultconfigs; do
    if [ -e "$MC/$d" ]; then
      mkdir -p "$BAK" && mv "$MC/$d" "$BAK/$d" && echo "Перенесено в резервную папку: $d"
    fi
  done
fi

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
step "Скачиваю и обновляю сборку (в первый раз ~1 ГБ, откроется окно с прогрессом)"
BOOT="$MC/packwiz-installer-bootstrap.jar"
[ -f "$BOOT" ] || curl -fsSL "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar" -o "$BOOT" || fail "не удалось скачать packwiz"
(cd "$MC" && "$JAVA" -jar "$BOOT" "$PACK_URL") || fail "скачивание сборки завершилось с ошибкой"

printf '\n\033[32mГотово!\033[0m\n'
echo "В лаунчере выберите версию: neoforge-$NEOFORGE_VERSION"
echo "Выделите игре памяти: на Маке с 8 ГБ — 5 ГБ, на компьютере с 16 ГБ и больше — 8 ГБ"
echo "Чтобы обновить сборку — просто запустите этот установщик ещё раз."
