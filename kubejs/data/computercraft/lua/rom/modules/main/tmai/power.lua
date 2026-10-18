-- tmai.power — питание ИИ.
-- Ядро ИИ — блок KubeJS "kubejs:ai_core" с FE-хранилищем. Его тик (server_scripts/tm_ai_core.js)
-- реально списывает энергию: idle + (сила редстоун-сигнала от компьютера) * k FE/t.
-- CC видит ядро как generic-периферию (getEnergy/getEnergyCapacity, тип "kubejs:ai_core").
-- Генератор (в капсуле — Powah furnator_starter) сам толкает энергию в ядро.
-- Ядро должно стоять ВПЛОТНУЮ к компьютеру (в капсуле — под ним): только так до него доходит редстоун-нагрузка.
-- Сторона находится сама (после переезда ядро могут поставить с любой стороны); tmai.power_side — предпочтительная.
-- Необязательно: Energy Detector (AP) в цепи генератор→ядро даёт реальный поток getTransferRate().

local util = require("tmai.util")

local M = {}

local core, detector
local side             -- сторона компьютера, к которой прилегает ядро (nil — ядро не вплотную)
local cfg = { min = 2000, side = "bottom", think = 15 }
local last = { t = nil, e = nil, rate = 0 }

function M.configure(c)
  cfg.min, cfg.side, cfg.think = c.power_min, c.power_side, c.power_think_level
end

function M.attach()
  core = peripheral.find("kubejs:ai_core")
  detector = peripheral.find("energy_detector")
  side = nil
  if peripheral.hasType(cfg.side, "kubejs:ai_core") then side = cfg.side
  else
    for _, s in ipairs(redstone.getSides()) do
      if peripheral.hasType(s, "kubejs:ai_core") then side = s; break end
    end
  end
  return core ~= nil
end

-- Состояние: { ok=bool, energy=, capacity=, pct=, delta=FE/t (изменение заряда), flow=FE/t|nil }
function M.status()
  if not core then M.attach() end
  if not core then return { ok = false, reason = "нет ядра", hint = "Ядро ИИ не подключено: поставьте его вплотную к терминалу." } end
  local okE, e = pcall(core.getEnergy)
  local okC, cap = pcall(core.getEnergyCapacity)
  -- ядро упаковано модулем переноса или чанк выгружен: методы отвечают пусто
  if not okE or not okC or type(e) ~= "number" or type(cap) ~= "number" then core = nil; return { ok = false, reason = "ядро недоступно" } end
  local t = os.epoch("utc")
  if last.t and t > last.t then
    local ticks = (t - last.t) / 50
    if ticks >= 20 then
      last.rate = (e - last.e) / ticks
      last.t, last.e = t, e
    end
  else
    last.t, last.e = t, e
  end
  local flow
  if detector then
    local ok, r = pcall(detector.getTransferRate)
    if ok then flow = r end
  end
  local far = side == nil   -- ядро видно только по проводной сети: нагрузку «думаю» до него не довести
  return {
    ok = e >= (cfg.min or 0) and not far, energy = e, capacity = cap, far = far,
    pct = cap > 0 and math.floor(e * 100 / cap) or 0,
    delta = last.rate, flow = flow,
    reason = far and "ядро не вплотную" or (e < (cfg.min or 0) and "мало энергии" or nil),
    hint = far and "Ядро ИИ стоит не вплотную к терминалу: поставьте его рядом (лучше под ним)." or nil,
  }
end

-- Нагрузка «думаю»: редстоун-сигнал в ядро увеличивает расход (реальная цена запроса).
function M.thinking(on)
  pcall(redstone.setAnalogOutput, side or cfg.side, on and cfg.think or 0)
end

-- Разовый «рывок» нагрузки (например, сканирование): уровень на N секунд, асинхронно не нужен.
function M.burst(level, seconds)
  pcall(redstone.setAnalogOutput, side or cfg.side, level)
  sleep(seconds)
  pcall(redstone.setAnalogOutput, side or cfg.side, 0)
end

function M.describe(st)
  if not st.energy then return "питание: " .. (st.reason or "?") end
  local s = string.format("заряд ядра %d%% (%d FE)", st.pct, st.energy)
  if st.flow then s = s .. string.format(", приток %d FE/t", st.flow) end
  if st.delta and st.delta < -0.5 then s = s .. string.format(", разряд %.1f FE/t", -st.delta) end
  if st.far then s = s .. "; ядро стоит не вплотную к терминалу — нейросеть не запускается, пока его не переставят" end
  return s
end

return M
