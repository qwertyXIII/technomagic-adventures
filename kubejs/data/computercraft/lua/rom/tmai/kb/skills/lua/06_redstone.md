REDSTONE API (стороны самого компьютера/черепашки: "top", "bottom", "left", "right", "front", "back"; redstone.getSides() → список)
- redstone.getInput(сторона) → bool; redstone.getAnalogInput(сторона) → 0–15.
- redstone.setOutput(сторона, bool); redstone.setAnalogOutput(сторона, 0–15); redstone.getOutput(сторона); redstone.getAnalogOutput(сторона).
- rs — то же самое (rs.setOutput…).
- Событие "redstone" (без аргументов) — изменился какой-то вход; какой — перечитай getInput.
- Выход держится, пока программа его не сменит. tmexec гасит выходы при остановке программы; при перезагрузке компьютера выходы тоже сбрасываются.

BUNDLED (цветные связки, если есть мод с bundled-кабелями; EnderIO даёт bundled-сигнал CC)
- redstone.setBundledOutput(сторона, colors.combine(colors.red, colors.blue)); getBundledInput(сторона) → маска; testBundledInput(сторона, colors.red) → bool.

РЕДСТОУН-РЕЛЕ CC (блок "Redstone Relay", тип "redstone_relay")
В Advanced Peripherals 0.8 нет Redstone Integrator — его заменяет реле CC: Tweaked. Ставится где угодно в проводной сети (или вплотную), даёт редстоун-сторон своего блока.
```lua
local relay = peripheral.find("redstone_relay") or error("No redstone relay", 0)
relay.setOutput("top", true)            -- те же методы, что у redstone API
print(relay.getAnalogInput("front"))    -- стороны: top, bottom, left, right, front, back — относительно лица реле
```
Если неясно, куда смотрит реле, — выведите входы всех сторон: for _, s in ipairs(redstone.getSides()) do print(s, relay.getAnalogInput(s)) end.

ПАТТЕРНЫ
```lua
-- импульс заданной длины
local function pulse(side, seconds)
  redstone.setOutput(side, true); sleep(seconds or 0.2); redstone.setOutput(side, false)
end

-- реакция на кнопку/рычаг без постоянного опроса
while true do
  os.pullEvent("redstone")
  if redstone.getInput("left") then print("Lever ON") else print("Lever OFF") end
end
```
- Дребезг: после изменения подожди sleep(0.1) и перечитай вход.
- Сигнал от компьютера идёт в соседний блок со стороны; для дальних целей — реле в сети или редстоун-провод/лампы.
- Компьютер сам по себе не «видит» силу компаратора у сундука — читай содержимое через inventory API, а не редстоуном.
