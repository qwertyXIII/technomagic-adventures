-- tmai.apps.mail — «Почта»: короткие письма между игроками. Учётных записей нет — ящик по нику.
-- Отправитель: у терминала — ctx.speaker() (без ника — отказ с подсказкой), с КПК — ник КПК, у нейросети — кто спросил.
-- Вкладка терминала — ящик игрока у терминала: «+ написать» (ник, затем текст; можно сразу «ник текст»),
--   Enter — прочитать (отмечается прочитанным; там же «Ответить»), Delete — удалить; внизу — у кого есть новые.
-- Доставка: письмо ложится в ящик получателя и сразу уходит на его КПК объявлением
--   { op="notify", text="Почта от X: …", level="info", from="Почта", app="mail", unread=N }.
-- КПК (radio): inbox, read, send, delete. Инструменты нейросети: mail_send, mail_inbox, mail_read.
-- Данные: ctx.data.boxes[ник в нижнем регистре] = { {id, from, to, text, t, read}, … } (старые первыми),
--   names[ник в нижнем регистре] = ник как пишет сам игрок (для КПК), next_id.

local json = require("tmai.json")
local text = require("tmai.text")
local util = require("tmai.util")

local M = { id = "mail", title = "Почта", short = "Почта", order = 65, monitor = false }

local TEXT_MAX, BOX_MAX, PREVIEW = 500, 60, 60

local function valid_player(n) return type(n) == "string" and #n >= 3 and #n <= 16 and n:match("^[A-Za-z0-9_]+$") ~= nil end
local function key(n) return n:lower() end

local function trim(s)
  s = tostring(s == nil and "" or s):gsub("[%z\1-\31]", " "):gsub("  +", " ")
  return (s:gsub("^ +", ""):gsub(" +$", ""))
end

local function clean_text(s)
  s = trim(s)
  if text.len(s) > TEXT_MAX then s = text.sub(s, 1, TEXT_MAX) end
  return s
end

local function preview(s, n)
  n = n or PREVIEW
  if text.len(s) <= n then return s end
  return text.sub(s, 1, n - 2) .. ".."
end

local function ago(t)
  local s = util.now() - (tonumber(t) or 0)
  if s < 90 then return "только что" end
  if s < 3600 then return math.floor(s / 60 + 0.5) .. " мин" end
  if s < 86400 * 2 then return math.floor(s / 3600 + 0.5) .. " ч" end
  return math.floor(s / 86400 + 0.5) .. " дн."
end

local V = { open = nil, compose = nil, msg = nil }   -- экран терминала (не сохраняется)
local function note(s, fg) V.msg = { text = s, fg = fg or colors.yellow, till = os.clock() + 30 } end

local function box(ctx, nick)
  local b = ctx.data.boxes[key(nick)]
  if not b then b = {}; ctx.data.boxes[key(nick)] = b end
  return b
end

local function unread(ctx, nick)
  local n = 0
  for _, m in ipairs(ctx.data.boxes[key(nick)] or {}) do if not m.read then n = n + 1 end end
  return n
end

-- Запомнить написание ника: names — как в игре (терминал, нейросеть), pda — как задан на КПК
-- (ctx.kpk ищет КПК по нику, с которым он выходил на связь, с точностью до регистра).
local function remember(ctx, nick, from_pda)
  if not valid_player(nick) then return end
  local d, k = ctx.data, key(nick)
  local changed = false
  if from_pda then
    if d.pda[k] ~= nick then d.pda[k] = nick; changed = true end
    if not d.names[k] then d.names[k] = nick; changed = true end
  elseif d.names[k] ~= nick then
    d.names[k] = nick; changed = true
  end
  if changed then ctx.save() end
end

local function display(ctx, nick) return ctx.data.names[key(nick)] or nick end

local function find_msg(ctx, nick, id)
  id = tonumber(id)
  for i, m in ipairs(ctx.data.boxes[key(nick)] or {}) do if m.id == id then return m, i end end
end

-- Отправить письмо -> письмо | nil, ошибка
local function send(ctx, from, to, body)
  if not valid_player(from) then
    return nil, "не знаю, кто пишет: подойдите к детектору игроков у терминала или выберите имя в «Чате» (щелчок по имени)"
  end
  to = trim(to):gsub("^@", "")
  if not valid_player(to) then return nil, "ник получателя — 3–16 латинских букв, цифр или _" end
  body = clean_text(body)
  if body == "" then return nil, "пустое письмо" end
  local d = ctx.data
  d.next_id = (tonumber(d.next_id) or 0) + 1
  if not d.names[key(to)] then d.names[key(to)] = to end
  local to_name = display(ctx, to)
  local m = { id = d.next_id, from = display(ctx, from), to = to_name, text = body, t = util.now(), read = false }
  local b = box(ctx, to)
  b[#b + 1] = m
  -- переполнение: сначала самые старые прочитанные, потом самые старые
  while #b > BOX_MAX do
    local drop = 1
    for i, x in ipairs(b) do if x.read then drop = i; break end end
    table.remove(b, drop)
  end
  ctx.save()
  local n = unread(ctx, to)
  local msg = { op = "notify", level = "info", from = "Почта", app = "mail", unread = n,
    text = "Почта от " .. m.from .. ": " .. preview(body, 120) }
  local sent, tried = false, {}
  for _, nick in ipairs({ d.pda[key(to)] or to_name, to_name, to }) do
    if not sent and not tried[nick] then
      tried[nick] = true
      sent = ctx.kpk(msg, nick) and true or false
    end
  end
  m.delivered = sent
  return m
end

local function remove(ctx, nick, id)
  local m, i = find_msg(ctx, nick, id)
  if not m then return nil end
  table.remove(ctx.data.boxes[key(nick)], i)
  ctx.save()
  return m
end

local function read(ctx, nick, id)
  local m = find_msg(ctx, nick, id)
  if not m then return nil end
  if not m.read then m.read = true; ctx.save() end
  return m
end

-- Список писем игрока для ответа (новые сверху).
local function inbox(ctx, nick, limit)
  local out = {}
  local b = ctx.data.boxes[key(nick)] or {}
  for i = #b, 1, -1 do
    local m = b[i]
    out[#out + 1] = { id = m.id, from = m.from, ago = ago(m.t), read = m.read and true or false, preview = preview(m.text) }
    if limit and #out >= limit then break end
  end
  return out
end

-- ---------- приложение ----------
function M.init(ctx)
  local d = ctx.data
  if type(d.boxes) ~= "table" then d.boxes = {} end
  if type(d.names) ~= "table" then d.names = {} end
  if type(d.pda) ~= "table" then d.pda = {} end
  d.next_id = tonumber(d.next_id) or 0
end

function M.status(ctx)
  local sp = ctx.speaker()
  local n = 0
  if sp then n = unread(ctx, sp)
  else for k in pairs(ctx.data.boxes) do n = n + unread(ctx, k) end end
  return n > 0 and ("непрочитанных: " .. n) or "новых нет"
end

local NEED = "Кто у терминала — неизвестно: подойдите к детектору или выберите имя в «Чате»"

local function open_rows(ctx, sp, m, out, w)
  local del = { op = "delete", id = m.id, label = "удалить письмо" }
  local n = unread(ctx, sp)
  out[#out + 1] = { text = "< к письмам", action = { op = "close", label = "к письмам" }, del = del,
    desc = n > 0 and ("Ещё непрочитанных: " .. n) or "Остальные письма прочитаны" }
  out[#out + 1] = { text = "От " .. tostring(m.from) .. " · " .. ago(m.t), header = true }
  for _, l in ipairs(text.wrap(m.text, math.max(10, (w or 51) - 4))) do out[#out + 1] = { text = l } end
  out[#out + 1] = { text = "Ответить " .. tostring(m.from), fg = colors.lime, del = del,
    prompt = { label = "Ответ " .. tostring(m.from), op = "reply", to = m.from, max = TEXT_MAX } }
  return out
end

function M.rows(ctx, w)
  local out = {}
  local sp = ctx.speaker()
  if V.msg and os.clock() < V.msg.till then out[1] = { text = V.msg.text, fg = V.msg.fg }
  else
    V.msg = nil
    out[1] = { text = sp and ("Ящик " .. sp .. ": непрочитанных " .. unread(ctx, sp)) or NEED,
      fg = sp and colors.lightGray or colors.orange }
  end
  if V.open and sp then
    local m = find_msg(ctx, sp, V.open)
    if m then return open_rows(ctx, sp, m, out, w) end
  end
  V.open = nil
  if V.compose then
    out[#out + 1] = { text = "Текст для " .. V.compose.to, fg = colors.lime,
      desc = "Enter — написать текст (Enter ещё раз — отправить)",
      prompt = { label = "Текст для " .. V.compose.to, op = "send", to = V.compose.to, max = TEXT_MAX } }
    out[#out + 1] = { text = "Отменить письмо", fg = colors.lightGray, action = { op = "cancel", label = "отменить письмо" } }
  else
    out[#out + 1] = { text = "+ написать", fg = colors.lime, desc = "Кому (ник), потом текст. Можно сразу: «ник текст»",
      prompt = { label = "Кому (ник)", op = "to", max = TEXT_MAX + 20 } }
  end
  if sp then
    local b = ctx.data.boxes[key(sp)] or {}
    out[#out + 1] = { text = "Входящие " .. sp, header = true }
    for i = #b, 1, -1 do
      local m = b[i]
      out[#out + 1] = { text = (m.read and "  " or "• ") .. tostring(m.from) .. ": " .. m.text, value = ago(m.t),
        fg = m.read and colors.lightGray or colors.white, desc = preview(m.text, 120),
        action = { op = "open", id = m.id, label = "прочитать" }, del = { op = "delete", id = m.id, label = "удалить" } }
    end
    if #b == 0 then out[#out + 1] = { text = "Писем нет", fg = colors.gray } end
  end
  -- у кого есть новые (без текста писем)
  local others = {}
  for k, b in pairs(ctx.data.boxes) do
    if not sp or k ~= key(sp) then
      local n = 0
      for _, m in ipairs(b) do if not m.read then n = n + 1 end end
      if n > 0 then others[#others + 1] = { name = display(ctx, k), n = n } end
    end
  end
  if #others > 0 then
    table.sort(others, function(a, b) return a.name < b.name end)
    out[#out + 1] = { text = "Ждут прочтения", header = true }
    for _, o in ipairs(others) do out[#out + 1] = { text = o.name, value = "новых: " .. o.n, fg = colors.gray } end
  end
  return out
end

local function sent_note(m)
  note("Письмо для " .. m.to .. (m.delivered and " доставлено на КПК" or " в ящике (КПК не на связи)"), colors.lime)
end

function M.action(ctx, act)
  local op, sp = act.op, act.player
  if sp then remember(ctx, sp) end
  if op == "open" then
    if not sp then note(NEED, colors.orange); return end
    if read(ctx, sp, act.id) then V.open = tonumber(act.id) end
  elseif op == "close" then
    V.open = nil
  elseif op == "delete" then
    if not sp then note(NEED, colors.orange); return end
    local m = remove(ctx, sp, act.id)
    V.open = nil
    if m then note("Письмо от " .. tostring(m.from) .. " удалено") end
  elseif op == "to" then
    local v = trim(act.value)
    local to, rest = v:match("^@?([A-Za-z0-9_]+)[ ,:]+(.+)$")
    if to and rest then                           -- сразу «ник текст»
      local m, err = send(ctx, sp, to, rest)
      if m then sent_note(m) else note(err, colors.orange) end
      return
    end
    to = v:gsub("^@", "")
    if not valid_player(to) then note("Ник получателя — 3–16 латинских букв, цифр или _", colors.orange); return end
    V.compose = { to = display(ctx, to) }
  elseif op == "send" or op == "reply" then
    local m, err = send(ctx, sp, act.to, act.value)
    if m then V.compose = nil; sent_note(m) else note(err, colors.orange) end
  elseif op == "cancel" then
    V.compose = nil
  end
end

-- ---------- КПК ----------
local NO_NICK = "у КПК не задан ник (set tmpda.player <ник>)"

M.radio = {
  inbox = function(ctx, msg, sender, player)
    if not player then return nil, NO_NICK end
    remember(ctx, player, true)
    return { unread = unread(ctx, player), items = inbox(ctx, player, 40) }
  end,
  read = function(ctx, msg, sender, player)
    if not player then return nil, NO_NICK end
    local m = read(ctx, player, msg.id)
    if not m then return nil, "нет такого письма" end
    return { id = m.id, from = m.from, ago = ago(m.t), text = m.text, unread = unread(ctx, player) }
  end,
  send = function(ctx, msg, sender, player)
    if not player then return nil, NO_NICK end
    remember(ctx, player, true)
    local m, err = send(ctx, player, type(msg.to) == "string" and msg.to or "", type(msg.text) == "string" and msg.text or "")
    if not m then return nil, err end
    return { id = m.id, to = m.to, delivered = m.delivered }
  end,
  delete = function(ctx, msg, sender, player)
    if not player then return nil, NO_NICK end
    local m = remove(ctx, player, msg.id)
    if not m then return nil, "нет такого письма" end
    return { deleted = m.id, unread = unread(ctx, player) }
  end,
}

-- ---------- нейросеть ----------
local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end
local S = function(d) return { type = "string", description = d } end
local N = function(d) return { type = "integer", description = d } end

function M.tools()
  return {
    { name = "mail_send", description = "Отправить письмо другому игроку от имени спросившего (ляжет в ящик и придёт на КПК получателя).",
      parameters = obj({ to = S("ник получателя"), text = S("текст письма, до 500 символов") }, { "to", "text" }) },
    { name = "mail_inbox", description = "Письма спросившего игрока: номер, от кого, когда, прочитано ли, начало текста (новые сверху).",
      parameters = obj({}) },
    { name = "mail_read", description = "Прочитать письмо спросившего игрока целиком по номеру из mail_inbox (отметится прочитанным).",
      parameters = obj({ id = N("номер письма") }, { "id" }) },
  }
end

function M.run_tool(ctx, name, a, tctx)
  local player = valid_player(tctx.player) and tctx.player or nil
  if not player then return "отказ: не знаю, кто спрашивает (ник игрока неизвестен) — почта по нику" end
  remember(ctx, player)
  if name == "mail_send" then
    local m, err = send(ctx, player, tostring(a.to or ""), tostring(a.text or ""))
    if not m then return "отказ: " .. tostring(err) end
    return { sent = m.id, to = m.to, delivered_to_pda = m.delivered }
  elseif name == "mail_inbox" then
    return { player = player, unread = unread(ctx, player), messages = inbox(ctx, player, 20) }
  elseif name == "mail_read" then
    local m = read(ctx, player, a.id)
    if not m then return "нет такого письма в ящике " .. player end
    return { id = m.id, from = m.from, when = ago(m.t), text = m.text }
  end
  return "нет такого инструмента"
end

M._t = { V = V, send = send, unread = unread, inbox = inbox }

return M
