-- tmai.history — память ИИ между сессиями.
--  /tmai/history.json — последние реплики {role, name, text, t}; общий диалог на троих,
--                       у каждой реплики игрока — ник говорящего.
--  /tmai/summary.txt  — сжатая сводка старого разговора (обновляется нейросетью, когда
--                       история превышает бюджет: старшая половина «сворачивается»).
--  /tmai/notes.json   — долговременные заметки (инструмент remember): базы, договорённости.

local util = require("tmai.util")
local u8 = require("tmai.u8")

local M = {}

local H_PATH = util.DATA_DIR .. "/history.json"
local S_PATH = util.DATA_DIR .. "/summary.txt"
local N_PATH = util.DATA_DIR .. "/notes.json"

local items, summary, notes
local budget = 5000

function M.init(history_chars)
  budget = history_chars or budget
  items = util.load_json(H_PATH, {})
  summary = util.read_file(S_PATH) or ""
  notes = util.load_json(N_PATH, {})
end

function M.add(role, name, text)
  items[#items + 1] = { role = role, name = name, text = u8.truncate(text, 2000), t = util.now() }
  util.save_json(H_PATH, items)
end

local function size()
  local n = 0
  for _, it in ipairs(items) do n = n + #it.text + 24 end
  return n
end

function M.needs_compaction() return size() > budget * 1.5 end

-- Свернуть старшую половину истории; summarize(text_old, summary_old) -> новая сводка | nil.
function M.compact(summarize)
  if #items < 6 then return false end
  local half = math.floor(#items / 2)
  local lines = {}
  for i = 1, half do
    local it = items[i]
    lines[#lines + 1] = (it.role == "user" and (it.name or "игрок") or "ИИ") .. ": " .. it.text
  end
  local new_summary = summarize(table.concat(lines, "\n"), summary)
  if not new_summary or new_summary == "" then return false end
  summary = u8.truncate(new_summary, 2500)
  util.write_file_atomic(S_PATH, summary)
  local rest = {}
  for i = half + 1, #items do rest[#rest + 1] = items[i] end
  items = rest
  util.save_json(H_PATH, items)
  return true
end

-- Сообщения для запроса (в общем формате: {role="user"/"assistant", content=...}),
-- последние реплики в пределах бюджета байт.
function M.messages()
  local out, used = {}, 0
  for i = #items, 1, -1 do
    local it = items[i]
    if used + #it.text > budget then break end
    table.insert(out, 1, { role = it.role, content = it.text, name = it.role == "user" and (it.name or "игрок") or nil })
    used = used + #it.text
  end
  -- провайдеры требуют, чтобы диалог начинался с user
  while out[1] and out[1].role ~= "user" do table.remove(out, 1) end
  return out
end

function M.summary() return summary end

function M.remember(text, who)
  text = u8.truncate(u8.trim(text or ""), 300)
  if text == "" then return nil, "пустая заметка" end
  notes[#notes + 1] = { text = text, by = who, t = util.now() }
  while #notes > 40 do table.remove(notes, 1) end
  util.save_json(N_PATH, notes)
  return #notes
end

function M.forget(index)
  index = tonumber(index)
  if not index or not notes[index] then return nil, "нет такой заметки" end
  table.remove(notes, index)
  util.save_json(N_PATH, notes)
  return true
end

function M.notes_text()
  local lines = {}
  for i, n in ipairs(notes) do lines[#lines + 1] = i .. ". " .. n.text end
  return table.concat(lines, "\n")
end

function M.clear()
  items = {}
  util.save_json(H_PATH, items)
end

return M
