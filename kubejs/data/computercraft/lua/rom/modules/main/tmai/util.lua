-- tmai.util — лог, файлы состояния, TSV-таблицы из ROM, мелочи.

local json = require("tmai.json")

local M = {}

M.DATA_DIR = "/tmai"          -- состояние на диске компьютера (сохраняется в мире)
M.ROM_DIR = "/rom/tmai"       -- данные из сборки (только чтение, приходят датапаком)

local debug_on = false
function M.set_debug(v) debug_on = v and true or false end

-- ---------- лог ----------
local LOG = M.DATA_DIR .. "/log.txt"
local LOG_MAX = 64 * 1024

function M.log(level, fmt, ...)
  if level == "D" and not debug_on then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  local line = string.format("[%s %s] %s\n", textutils and textutils.formatTime(os.time(), true) or "?", level, msg)
  if not fs.exists(M.DATA_DIR) then fs.makeDir(M.DATA_DIR) end
  if fs.exists(LOG) and fs.getSize(LOG) > LOG_MAX then
    if fs.exists(LOG .. ".1") then fs.delete(LOG .. ".1") end
    fs.move(LOG, LOG .. ".1")
  end
  local h = fs.open(LOG, "a")
  if h then h.write(line); h.close() end
end

-- ---------- файлы ----------
function M.read_file(path)
  local h = fs.open(path, "rb") or fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

function M.write_file_atomic(path, data)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "wb") or fs.open(tmp, "w")
  if not h then return false end
  h.write(data)
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

function M.load_json(path, default)
  local s = M.read_file(path)
  if not s then return default end
  local v = json.decode(s)
  if type(v) ~= "table" then
    M.log("W", "broken json %s, using default", path)
    return default
  end
  return v
end

function M.save_json(path, value)
  return M.write_file_atomic(path, json.encode(value))
end

-- TSV из ROM: первая строка — заголовки, строки с # — комментарии.
function M.read_tsv(path)
  local s = M.read_file(path)
  local rows = {}
  if not s then return rows end
  local header
  for line in (s .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local cols = {}
      for c in (line .. "\t"):gmatch("(.-)\t") do cols[#cols + 1] = c end
      if not header then header = cols
      else
        local row = {}
        for i, h in ipairs(header) do row[h] = cols[i] or "" end
        rows[#rows + 1] = row
      end
    end
  end
  return rows
end

-- ---------- время ----------
function M.now() return os.epoch("utc") / 1000 end -- секунды реального времени

-- Отдать управление планировщику CC внутри тяжёлого цикла
-- (защита от "Too long without yielding"). Событие с уникальным именем,
-- чужие события при этом другим корутинам parallel не теряются.
function M.yield()
  os.queueEvent("tmai_yield")
  os.pullEvent("tmai_yield")
end

function M.copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

return M
