-- tmai.feed — лента разговора с ЛОЦМАНом: то, что видно во вкладке «Чат» терминала и монитора.
-- Сюда попадают вопросы игроков (с терминала и с КПК), ответы, системные сообщения капсулы.
-- Хранится в /tmai/feed.json (последние MAX записей) — переживает перезагрузку компьютера.
--   feed.add(kind, who, text)   kind: "user" | "ai" | "sys" | "warn"
--   feed.items()                список { kind, who, text, t, day }
--   feed.version                растёт с каждой записью (экраны перерисовываются, когда он меняется)

local util = require("tmai.util")

local M = {}

local PATH = util.DATA_DIR .. "/feed.json"
local MAX = 150
local items

M.version = 0

local function load()
  if items then return end
  items = util.load_json(PATH, {})
  if type(items) ~= "table" then items = {} end
end

function M.add(kind, who, text)
  load()
  text = tostring(text or "")
  if text == "" then return end
  items[#items + 1] = { kind = kind or "sys", who = who, text = text, t = textutils.formatTime(os.time(), true), day = os.day() }
  while #items > MAX do table.remove(items, 1) end
  M.version = M.version + 1
  util.save_json(PATH, items)
  os.queueEvent("tmai_ui", "feed")
end

function M.items()
  load()
  return items
end

function M.clear()
  items = {}
  M.version = M.version + 1
  util.save_json(PATH, items)
end

return M
