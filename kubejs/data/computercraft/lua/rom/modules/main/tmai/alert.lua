-- tmai.alert — тревоги ЛОЦМАНа: одно сообщение в ленту, на КПК и звуком колонки, без повторов.
-- Приложения поднимают тревогу по ключу («base.energy», «storage.full»…). Пока тревога висит, тот же текст
-- не повторяется чаще cooldown секунд; clear(ключ) снимает её (и, если передан текст, сообщает «норма»).
-- Активные тревоги видны на «Главной» и в строке состояния. Хранятся в state.alerts (переживают перезапуск).
--   alert.raise(key, text, { level = "warn"|"crit"|"info", cooldown = 600, app = "base" }) -> true, если сообщили
--   alert.clear(key [, text])     alert.list() -> { {key, text, level, t, app}, … } новые сверху
--   alert.count() -> число активных

local util = require("tmai.util")

local M = {}

local st                 -- state.alerts
local notify = function() end   -- notify(text, level): лента + КПК + звук (задаёт app.lua)
local save = function() end

local LEVELS = { info = true, warn = true, crit = true }

function M.init(state, notify_fn, save_fn)
  state.alerts = state.alerts or {}
  st = state.alerts
  notify = notify_fn or notify
  save = save_fn or save
end

function M.raise(key, text, opts)
  if type(key) ~= "string" or type(text) ~= "string" or text == "" then return false end
  opts = opts or {}
  local level = LEVELS[opts.level] and opts.level or "warn"
  local now = util.now()
  local a = st[key]
  if a and a.text == text and now - (a.t or 0) < (tonumber(opts.cooldown) or 600) then return false end
  st[key] = { text = text, level = level, t = now, app = opts.app }
  notify(text, level)
  save()
  return true
end

function M.clear(key, text)
  if not st[key] then return false end
  st[key] = nil
  if type(text) == "string" and text ~= "" then notify(text, "info") end
  save()
  return true
end

function M.active(key) return st[key] ~= nil end

function M.list()
  local out = {}
  for k, a in pairs(st) do out[#out + 1] = { key = k, text = a.text, level = a.level, t = a.t, app = a.app } end
  table.sort(out, function(x, y) return (x.t or 0) > (y.t or 0) end)
  return out
end

function M.count()
  local n = 0
  for _ in pairs(st) do n = n + 1 end
  return n
end

return M
