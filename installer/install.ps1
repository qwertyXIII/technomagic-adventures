# Установка и обновление сборки TechnoMagic Adventures (Windows).
# Ставит NeoForge, при первом запуске убирает старые моды в резервную папку,
# затем скачивает и синхронизирует моды, настройки, пакеты ресурсов и шейдеры.
# Запускать можно сколько угодно раз: повторный запуск = обновление сборки.
# -Graphics (TechnoMagic-Windows-Graphics.bat): заново показать окно выбора необязательных
# «красивостей» (шейдеры, анимации мобов, звук и т.п.) — сбрасывает только сохранённый выбор.

param([switch]$Graphics)

# Continue, а не Stop: в Windows PowerShell 5.1 вывод java в stderr при Stop обрывает скрипт.
# Ошибки проверяем явно; сетевые вызовы — с -ErrorAction Stop.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PackUrl = "https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/pack.toml"
$NeoForgeVersion = "21.1.262"
$Mc = Join-Path $env:APPDATA ".minecraft"
$Tools = Join-Path $env:LOCALAPPDATA "TechnoMagic"

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host ""; Write-Host "ОШИБКА: $text" -ForegroundColor Red; exit 1 }

function Test-Java21($exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    $out = & $exe -version 2>&1 | Out-String
    return $out -match 'version "(2[1-9]|[3-9]\d)'
}

function Find-Java {
    $candidates = @(
        (Join-Path $Mc "runtime\java-runtime-delta\windows\java-runtime-delta\bin\java.exe"),
        (Join-Path $Tools "jre\bin\java.exe")
    )
    $onPath = Get-Command java -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($c in $candidates) { if (Test-Java21 $c) { return $c } }

    Step "Java 21 не найдена — скачиваю (Eclipse Temurin, ~45 МБ)"
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $zip = Join-Path $Tools "jre.zip"
    Invoke-WebRequest -UseBasicParsing -Uri "https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse" -OutFile $zip -ErrorAction Stop
    $tmp = Join-Path $Tools "jre-unpack"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $zip -DestinationPath $tmp
    $root = Get-ChildItem $tmp -Directory | Select-Object -First 1
    $dest = Join-Path $Tools "jre"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Move-Item $root.FullName $dest
    Remove-Item -Recurse -Force $tmp, $zip
    $exe = Join-Path $dest "bin\java.exe"
    if (-not (Test-Java21 $exe)) { Fail "не удалось подготовить Java 21" }
    return $exe
}

# Сброс сохранённого выбора необязательных модов, чтобы packwiz-installer снова показал окно с галочками.
# packwiz-installer хранит выбор в packwiz.json: cachedFiles.<файл>.isOptional / optionValue.
# Если у записи нет isOptional и не совпадает hash, он перечитывает метаданные, видит опцию как «новую»
# и показывает окно (со значениями по умолчанию). packFileHash/indexFileHash убираем, иначе при
# неизменной сборке он вообще не дойдёт до списка файлов. Остальное (где лежат файлы) не трогаем —
# так выключенные пункты удаляются с диска, а включённые не скачиваются заново.
function Reset-OptionalChoice($path) {
    if (-not (Test-Path $path)) { return }
    $ErrorActionPreference = "Stop"   # только внутри функции: любая ошибка — в catch
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $data = $ser.DeserializeObject([System.IO.File]::ReadAllText($path))
        $count = 0
        $files = $data["cachedFiles"]
        if ($files -is [System.Collections.IDictionary]) {
            foreach ($f in @($files.Values)) {
                if ($f -is [System.Collections.IDictionary] -and $f["isOptional"] -eq $true) {
                    [void]$f.Remove("isOptional")
                    [void]$f.Remove("hash")
                    $count++
                }
            }
        }
        [void]$data.Remove("packFileHash")
        [void]$data.Remove("indexFileHash")
        [System.IO.File]::WriteAllText($path, $ser.Serialize($data), (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Сброшен сохранённый выбор (пунктов: $count)"
    } catch {
        # Повреждённый файл: убираем в сторону, packwiz-installer соберёт его заново
        # (сверит уже скачанные файлы по хэшам, повторно качать всё не будет).
        Move-Item $path "$path.bad" -Force -ErrorAction SilentlyContinue
        Write-Host "Файл состояния packwiz.json не прочитался — переименован в packwiz.json.bad"
    }
}

Write-Host "TechnoMagic Adventures — установка / обновление" -ForegroundColor Green
Write-Host "Папка игры: $Mc"

if (Get-Process java, javaw -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "Minecraft*" }) {
    Fail "игра сейчас запущена. Закройте Minecraft и запустите установщик снова."
}

New-Item -ItemType Directory -Force -Path $Mc | Out-Null
$Java = Find-Java
Write-Host "Java: $Java"

# 1. NeoForge
$nfDir = Join-Path $Mc "versions\neoforge-$NeoForgeVersion"
if (Test-Path $nfDir) {
    Step "NeoForge $NeoForgeVersion уже установлен"
} else {
    Step "Устанавливаю NeoForge $NeoForgeVersion"
    $profiles = Join-Path $Mc "launcher_profiles.json"
    if (-not (Test-Path $profiles)) { Set-Content -Path $profiles -Value '{"profiles":{}}' -Encoding ASCII }
    $inst = Join-Path $env:TEMP "neoforge-$NeoForgeVersion-installer.jar"
    Invoke-WebRequest -UseBasicParsing -Uri "https://maven.neoforged.net/releases/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-installer.jar" -OutFile $inst -ErrorAction Stop
    Push-Location $env:TEMP
    & $Java -jar $inst --installClient $Mc | Select-Object -Last 2
    Pop-Location
    if (-not (Test-Path $nfDir)) { Fail "NeoForge не установился" }
}

# 2. Первый запуск: старые моды и настройки — в резервную папку (ничего не удаляется).
# Признак установки — свой файл-метка; packwiz.json (состояние packwiz-installer) тоже считается
# признаком, чтобы не трогать тех, кто ставил сборку до появления метки.
$marker = Join-Path $Mc "technomagic-installed.txt"
$manifest = Join-Path $Mc "packwiz.json"
if (-not (Test-Path $marker) -and -not (Test-Path $manifest)) {
    $existing = @("mods", "config", "defaultconfigs") | Where-Object { Test-Path (Join-Path $Mc $_) }
    if ($existing) {
        $bak = Join-Path $Mc ("_backup_" + (Get-Date -Format "yyyy-MM-dd_HHmm"))
        Step "Убираю старые моды и настройки в $bak"
        New-Item -ItemType Directory -Path $bak | Out-Null
        foreach ($d in $existing) {
            try { Move-Item (Join-Path $Mc $d) (Join-Path $bak $d) -ErrorAction Stop }
            catch { Fail "не удалось перенести $d в резервную папку: $($_.Exception.Message)" }
        }
    }
}
if (-not (Test-Path $marker)) {
    Set-Content -Path $marker -Encoding ASCII -Value "TechnoMagic Adventures installer marker ($(Get-Date -Format 'yyyy-MM-dd HH:mm')): the pack is installed here, old mods/config are moved to a backup only on the very first install."
}

# 3. Копия миров перед обновлением: только миры, в которые играли последние 14 дней; храним 3 последние копии
$saves = Join-Path $Mc "saves"
$recent = @()
if (Test-Path $saves) {
    $recent = Get-ChildItem $saves -Directory | Where-Object {
        $lvl = Join-Path $_.FullName "level.dat"
        (Test-Path $lvl) -and ((Get-Item $lvl).LastWriteTime -gt (Get-Date).AddDays(-14))
    }
}
if ($recent) {
    $backupRoot = Join-Path $Mc "_world_backups"
    $dest = Join-Path $backupRoot (Get-Date -Format "yyyy-MM-dd_HHmm")
    Step "Сохраняю копию миров перед обновлением: $dest"
    foreach ($w in $recent) {
        robocopy $w.FullName (Join-Path $dest $w.Name) /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "не удалось скопировать мир $($w.Name) (robocopy $LASTEXITCODE). Обновление отменено, мир не тронут." }
        Write-Host "  $($w.Name)"
    }
    Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
}

# 4. Моды, настройки, пакеты ресурсов, шейдеры
if ($Graphics) {
    Step "Изменение набора графики: сейчас откроется окно с галочками"
    Write-Host "Все пункты будут включены (как для мощного ПК). Для лёгкого режима снимите галочки и нажмите OK."
    Reset-OptionalChoice $manifest
}
Step "Скачиваю и обновляю сборку (в первый раз ~1 ГБ, откроется окно с прогрессом)"
$boot = Join-Path $Mc "packwiz-installer-bootstrap.jar"
if (-not (Test-Path $boot)) {
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar" -OutFile $boot -ErrorAction Stop
}
Push-Location $Mc
& $Java -jar $boot $PackUrl
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { Fail "скачивание сборки завершилось с ошибкой (код $code)" }

# Связка EMF + ETF + Fresh Animations: packwiz не умеет зависимости между галочками — проверяем сами
$modsDir = Join-Path $Mc "mods"
$hasEmf = [bool](Get-ChildItem $modsDir -Filter "entity_model_features-*.jar" -ErrorAction SilentlyContinue)
$hasEtf = [bool](Get-ChildItem $modsDir -Filter "entity_texture_features-*.jar" -ErrorAction SilentlyContinue)
$hasFa = [bool](Get-ChildItem (Join-Path $Mc "resourcepacks") -Filter "FreshAnimations*" -ErrorAction SilentlyContinue)
if ($hasEmf -and -not $hasEtf) {
    Write-Host ""
    Write-Host "ВНИМАНИЕ: включён EMF без ETF — игра не запустится. Запустите TechnoMagic-Windows-Graphics.bat и включите оба (или выключите оба)." -ForegroundColor Yellow
} elseif ($hasFa -and -not ($hasEmf -and $hasEtf)) {
    Write-Host ""
    Write-Host "Fresh Animations без EMF и ETF работать не будет (игра запустится). Поменять выбор: TechnoMagic-Windows-Graphics.bat" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Готово!" -ForegroundColor Green
Write-Host "В лаунчере выберите версию: neoforge-$NeoForgeVersion"
Write-Host "Выделите игре памяти: 8 ГБ (если на компьютере 16 ГБ и больше)"
Write-Host "Чтобы обновить сборку — просто запустите этот установщик ещё раз."
Write-Host "Чтобы поменять набор графики (лёгкий режим для слабых компьютеров) — TechnoMagic-Windows-Graphics.bat."
