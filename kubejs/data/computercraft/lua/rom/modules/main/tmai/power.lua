-- tmai.power — питание ИИ.
-- Ядро ИИ — блок KubeJS "kubejs:ai_core" с FE-хранилищем. Его тик (server_scripts/tm_ai_core.js)
-- реально списывает энергию: idle + (сила редстоун-сигнала от компьютера) * k FE/t.
-- CC видит ядро как generic-периферию (getEnergy/getEnergyCapacity, тип "kubejs:ai_core").
-- Генератор (в капсуле — Powah furnator_starter) сам толкает энергию в ядро.
-- Необязательно: Energy Detector (AP) в цепи генератор→ядро даёт реальный поток getTransferRate().

local util = require("tmai.util")

local M = {}

local core, detector
local cfg = { min = 2000, side = "bottom", think = 15 }
local last = { t = nil, e = nil, rate = 0 }

function M.configure(c)
  cfg.min, cfg.side, cfg.think = c.power_min, c.power_side, c.power_think_level
end

function M.attach()
  core = peripheral.find("kubejs:ai_core")
  detector = peripheral.find("energy_detector")
  return core ~= nil
end

-- Состояние: { ok=bool, energy=, capacity=, pct=, delta=FE/t (изменение заряда), flow=FE/t|nil }
function M.status()
  if not core then M.attach() end
  if not core then return { ok = false, reason = "нет ядра" } end
  local okE, e = pcall(core.getEnergy)
  local okC, cap = pcall(core.getEnergyCapacity)
  if not okE or not okC then core = nil; return { ok = false, reason = "ядро недоступно" } end
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
  return {
    ok = e >= cfg.min, energy = e, capacity = cap,
    pct = cap > 0 and math.floor(e * 100 / cap) or 0,
    delta = last.rate, flow = flow,
    reason = e < cfg.min and "мало энергии" or nil,
  }
end

-- Нагрузка «думаю»: редстоун-сигнал в ядро увеличивает расход (реальная цена запроса).
function M.thinking(on)
  pcall(redstone.setAnalogOutput, cfg.side, on and cfg.think or 0)
end

-- Разовый «рывок» нагрузки (например, сканирование): уровень на N секунд, асинхронно не нужен.
function M.burst(level, seconds)
  pcall(redstone.setAnalogOutput, cfg.side, level)
  sleep(seconds)
  pcall(redstone.setAnalogOutput, cfg.side, 0)
end

function M.describe(st)
  if not st.energy then return "питание: " .. (st.reason or "?") end
  local s = string.format("заряд ядра %d%% (%d FE)", st.pct, st.energy)
  if st.flow then s = s .. string.format(", приток %d FE/t", st.flow) end
  if st.delta and st.delta < -0.5 then s = s .. string.format(", разряд %.1f FE/t", -st.delta) end
  return s
end

return M
