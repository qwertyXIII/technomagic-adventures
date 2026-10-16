-- tmai.tools — инструменты (function calling). Нейросеть получает ТОЛЬКО этот белый список;
-- каждый аргумент проверяется здесь. Ник игрока берётся из контекста запроса, а не из
-- аргументов модели (модель не может выдать награду «другому игроку»).
-- Набор инструментов динамический: МЭ-инструменты — только если ME Bridge подключён, и т.д.
-- Это экономит токены (описания инструментов уходят в каждом запросе).

local kb = require("tmai.kb")
local lore = require("tmai.lore")
local me = require("tmai.me")
local power = require("tmai.power")
local quests = require("tmai.quests")
local history = require("tmai.history")
local scripts = require("tmai.scripts")
local link = require("tmai.link")
local util = require("tmai.util")
local json = require("tmai.json")

local M = {}

local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local S = function(d) return { type = "string", description = d } end
local N = function(d) return { type = "integer", description = d } end

local DEFS = {
  base = {
    { name = "kb_search", description = "Найти разделы справочника по модам и сборке. Вернёт id и заголовки.",
      parameters = obj({ query = S("что искать, по-русски или ID мода/предмета") }, { "query" }) },
    { name = "kb_read", description = "Прочитать раздел справочника целиком по id.",
      parameters = obj({ id = S("id раздела из kb_search") }, { "id" }) },
    { name = "memory_list", description = "Список находок, которые экипаж положил в Ящик памяти (записки, журналы).",
      parameters = obj({}) },
    { name = "memory_read", description = "Прочитать находку из Ящика памяти целиком (если сектор памяти для неё открыт).",
      parameters = obj({ item = S("item или название из memory_list") }, { "item" }) },
    { name = "remember", description = "Сохранить важный факт надолго (база игрока, договорённость, координаты).",
      parameters = obj({ text = S("факт, до 300 символов") }, { "text" }) },
    { name = "forget", description = "Удалить долговременную заметку по номеру.",
      parameters = obj({ index = N("номер заметки") }, { "index" }) },
    { name = "power_status", description = "Состояние питания ядра ИИ и генератора.",
      parameters = obj({}) },
    { name = "comm_status", description = "Связь капсулы: радио, вышки-ретрансляторы и их дальность.",
      parameters = obj({}) },
  },
  me = {
    { name = "me_status", description = "Состояние МЭ-сети (заполненность, энергия, процессоры крафта).", parameters = obj({}) },
    { name = "me_find", description = "Найти предметы в МЭ-сети по названию или ID; вернёт ID и количество.",
      parameters = obj({ query = S("часть названия или ID") }, { "query" }) },
    { name = "me_craftable", description = "Найти, что МЭ-сеть умеет автокрафтить.",
      parameters = obj({ query = S("часть названия или ID") }, { "query" }) },
    { name = "me_craft", description = "Заказать автокрафт. Крупный заказ вернёт код — игрок подтверждает сам.",
      parameters = obj({ item = S("точный ID предмета, напр. minecraft:iron_ingot"), count = N("сколько") }, { "item", "count" }) },
    { name = "me_jobs", description = "Состояние заказанных автокрафтов.", parameters = obj({}) },
  },
  nav = {
    { name = "scout_targets", description = "Какие цели может найти навигационный модуль сейчас (зависит от ремонта).",
      parameters = obj({}) },
    { name = "scout_locate", description = "Найти ближайшую к игроку цель из scout_targets. Тратит энергию, есть перезарядка.",
      parameters = obj({ target = S("id цели из scout_targets") }, { "target" }) },
    { name = "quest_list", description = "Доступные побочные задания.", parameters = obj({}) },
    { name = "quest_accept", description = "Взять задание для спрашивающего игрока.",
      parameters = obj({ id = S("id задания из quest_list") }, { "id" }) },
    { name = "quest_status", description = "Текущее задание и прогресс.", parameters = obj({}) },
    { name = "quest_abandon", description = "Отменить текущее задание.", parameters = obj({}) },
    { name = "player_position", description = "Где сейчас спрашивающий игрок (координаты и измерение).", parameters = obj({}) },
  },
  scripts = {
    { name = "computers_list", description = "Компьютеры/черепашки с агентом tmexec, на которых можно запускать скрипты.",
      parameters = obj({}) },
    { name = "script_propose", description = "Предложить Lua-программу для CC: Tweaked. Она будет записана на целевой компьютер, запуск — после подтверждения игроком.",
      parameters = obj({ target = N("ID компьютера из computers_list"), name = S("латиницей, до 24 символов"),
        description = S("что делает программа"), code = S("полный код Lua") }, { "target", "name", "code" }) },
    { name = "script_status", description = "Статус запущенных скриптов (вывод, ошибки).",
      parameters = obj({ job = S("код задания, необязательно") }) },
    { name = "script_stop", description = "Остановить скрипт по коду задания (или все).",
      parameters = obj({ job = S("код задания, пусто = все") }) },
  },
}

-- Список инструментов под текущее оборудование.
function M.available(ctx)
  local list = {}
  local function add(group) for _, d in ipairs(DEFS[group]) do list[#list + 1] = d end end
  add("base")
  if ctx.has_me then add("me") end
  if ctx.has_nav then add("nav") end
  if ctx.has_exec then add("scripts") end
  return list
end

local function str(v, max) v = tostring(v or ""); return v:sub(1, max or 200) end

-- Выполнить инструмент. ctx = { player=, lore_level=, repair=, cfg= }
function M.run(name, a, ctx)
  if name == "kb_search" then return kb.tool_search(str(a.query), ctx.lore_level)
  elseif name == "kb_read" then return kb.tool_read(str(a.id, 64), ctx.lore_level) or "нет такого раздела"
  elseif name == "memory_list" then local l = lore.list(); return { records = l }
  elseif name == "memory_read" then return lore.memory_read(str(a.item, 80)) or "запись не найдена"
  elseif name == "remember" then local n, e = history.remember(str(a.text, 300), ctx.player); return n and ("сохранено как №" .. n) or e
  elseif name == "forget" then local ok, e = history.forget(a.index); return ok and "удалено" or e
  elseif name == "power_status" then return power.status()
  elseif name == "comm_status" then return { relays = require("tmai.guard").relays() }

  elseif name == "me_status" then return me.status()
  elseif name == "me_find" then local r, e = me.find(str(a.query, 64)); return r or e
  elseif name == "me_craftable" then local r, e = me.find_craftable(str(a.query, 64)); return r or e
  elseif name == "me_craft" then local r, e = me.request_craft(str(a.item, 100), a.count, ctx.player, ctx.cfg); return r or ("отказ: " .. tostring(e))
  elseif name == "me_jobs" then return me.jobs_summary()

  elseif name == "scout_targets" then local r, e = link.call("scout_list", {}); return r or e
  elseif name == "scout_locate" then
    local st = power.status()
    if not st.ok then return "отказ: недостаточно энергии для сканирования" end
    power.thinking(true)
    local r, e = link.call("locate", { target = str(a.target, 64), player = ctx.player }, 30)
    power.thinking(false)
    return r or ("отказ: " .. tostring(e))
  elseif name == "quest_list" then return quests.available(ctx.repair)
  elseif name == "quest_accept" then local r, e = quests.accept(str(a.id, 40), ctx.player, ctx.repair); return r or ("отказ: " .. tostring(e))
  elseif name == "quest_status" then return quests.active() or "активного задания нет"
  elseif name == "quest_abandon" then quests.abandon(); return "задание отменено"
  elseif name == "player_position" then local r, e = link.call("pos", { player = ctx.player }); return r or e

  elseif name == "computers_list" then return scripts.list_targets()
  elseif name == "script_propose" then local r, e = scripts.propose(a, ctx.player); return r or ("отказ: " .. tostring(e))
  elseif name == "script_status" then return scripts.status(a.job and str(a.job, 8) or nil)
  elseif name == "script_stop" then return "остановлено: " .. scripts.stop(a.job and a.job ~= "" and str(a.job, 8) or nil)
  end
  util.log("W", "unknown tool %s", tostring(name))
  return "нет такого инструмента"
end

return M
