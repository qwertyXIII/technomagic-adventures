-- tmpda.mail — вкладка «Почта» КПК: входящие игрока с этим КПК, чтение, ответ, новое письмо.
-- Письма хранит приложение «Почта» капсулы (запросы inbox, read, send, delete); новое письмо приходит
-- объявлением {op="notify", app="mail", unread=N} — вкладка помечается «*», список обновляется.
-- Список: «+ написать» (ник, затем текст; можно сразу «ник текст»), Enter — прочитать, Delete — удалить (дважды).
-- Письмо: ↑↓ — листать, R — ответить, Delete — удалить, Backspace/Enter — назад; кнопки внизу — касанием.

local text = require("tmai.text")
local L = require("tmpda.list")

local T = { id = "mail", title = "Почта", short = "Почт" }

local REFRESH = 60

local function save(K, st) K:save("mail", { items = st.items, unread = st.unread, stamp = st.stamp }) end

function T.init(K, st)
  local c = K:load("mail", {})
  st.items = type(c.items) == "table" and c.items or {}
  st.unread = tonumber(c.unread) or 0
  st.stamp = c.stamp
  st.view, st.lst, st.top = "list", {}, 1
end

local function refresh(K, st, quiet)
  if st.loading then return end
  st.loading = true
  st.next = K:clock() + REFRESH
  K:request("mail", "inbox", {}, function(data, err)
    st.loading = false
    if type(data) ~= "table" then
      st.err = err or "нет ответа"
      if not quiet then K:flash(st.err, colors.orange) end
      return
    end
    local sel = st.lst.sel and st.lst.sel > 1 and st.items[st.lst.sel - 1]   -- выбор — на том же письме
    st.items = type(data.items) == "table" and data.items or {}
    if sel then
      for i, it in ipairs(st.items) do if it.id == sel.id then st.lst.sel = i + 1 end end
    end
    st.unread = tonumber(data.unread) or 0
    st.err, st.stamp, st.dirty = nil, K:stamp(), false
    save(K, st)
  end)
end
T.refresh = refresh

function T.show(K, st)
  if st.dirty or not st.next or K:clock() >= st.next then refresh(K, st, true) end
end

function T.tick(K)
  local st = K.st.mail
  if not st.started and K.link == "на связи" and not K:busy() then
    st.started = true             -- первый раз на связи: счётчик непрочитанных (и капсула узнаёт ник этого КПК)
    return refresh(K, st, true)
  end
  if K:tab().id == "mail" and st.view == "list" and not K.prompt and (st.dirty or (st.next and K:clock() >= st.next)) then
    refresh(K, st, true)
  end
end

-- Новое письмо: объявление капсулы с app="mail".
function T.notify(K, m)
  if m.app ~= "mail" then return end
  local st = K.st.mail
  st.unread = tonumber(m.unread) or (st.unread + 1)
  st.dirty = true
  if K:tab().id == "mail" and st.view == "list" and not K.prompt then refresh(K, st, true) end
end

function T.badge(K, st) return (st.unread or 0) > 0 and colors.yellow or nil end

local function list_rows(st)
  local rows = { { text = "+ написать", fg = colors.lime, sel = true, act = "write" } }
  for _, m in ipairs(st.items) do
    rows[#rows + 1] = { text = (m.read and "" or "• ") .. tostring(m.from), right = tostring(m.ago or ""),
      fg = m.read and colors.lightGray or colors.white, sel = true, msg = m, sub = tostring(m.preview or ""),
      sub_fg = m.read and colors.gray or colors.lightGray }
  end
  if #st.items == 0 then
    rows[#rows + 1] = { text = st.stamp and "Писем нет." or "Нет данных: R — обновить.", fg = colors.gray }
  end
  return rows
end

-- ---------- письмо ----------
local BUTTONS = { { label = "[Назад]", act = "back" }, { label = "[Ответ]", act = "reply" }, { label = "[Удалить]", act = "delete" } }

local function read_lines(st, w)
  local m = st.msg
  if st.rl and st.rl.w == w and st.rl.id == m.id then return st.rl.lines end
  local lines = text.wrap(tostring(m.text or ""), w)
  st.rl = { w = w, id = m.id, lines = lines }
  return lines
end

function T.draw(K, st, x, y, w, h)
  if st.view == "read" and st.msg then
    local m = st.msg
    K:put(x, y, text.fit("От " .. tostring(m.from) .. " · " .. tostring(m.ago or ""), w, ".."), colors.cyan, colors.black)
    local lines = read_lines(st, w)
    st.top = math.max(1, math.min(st.top or 1, math.max(1, #lines - (h - 2))))
    for i = 0, h - 2 do
      local l = lines[st.top + i]
      if l then K:put(x, y + 1 + i, l, colors.white, colors.black) end
    end
    return
  end
  st.view = "list"
  L.draw(function(t, ...) K:put(...) end, K.t, x, y, w, h, list_rows(st), st.lst)
end

local function send(K, st, to, body)
  K:request("mail", "send", { to = to, text = body }, function(data, err)
    if not data then K:flash(err, colors.orange); return end
    K:flash((data.delivered and "Доставлено: " or "В ящике: ") .. tostring(data.to), colors.lime)
  end)
end

local function valid(n) return type(n) == "string" and #n >= 3 and #n <= 16 and n:match("^[A-Za-z0-9_]+$") ~= nil end

local function write(K, st)
  K:ask("Кому", { max = 320, placeholder = "ник (или «ник текст»)" }, function(v)
    v = tostring(v or ""):gsub("^[ ]+", ""):gsub("[ ]+$", ""):gsub("^@", "")
    local to, rest = v:match("^([A-Za-z0-9_]+)[ ,:]+(.+)$")
    if to and rest then
      if not valid(to) then K:flash("Ник: латиница, цифры, _", colors.orange); return end
      return send(K, st, to, rest)
    end
    if not valid(v) then K:flash("Ник: латиница, цифры, _", colors.orange); return end
    K:ask("Текст", { max = 300, placeholder = "письмо для " .. v }, function(body)
      if not tostring(body or ""):match("[^ ]") then K:flash("Пустое письмо не отправлено", colors.orange); return end
      send(K, st, v, body)
    end)
  end)
end

local function open(K, st, m)
  K:request("mail", "read", { id = m.id }, function(data, err)
    if not data then K:flash(err, colors.orange); return end
    if not m.read then m.read = true end
    st.unread = tonumber(data.unread) or st.unread
    st.msg, st.view, st.top = data, "read", 1
    K.flash_msg = nil                -- строка кнопок видна сразу
    save(K, st)
  end)
end

local function delete(K, st, m)
  if not K:confirm("mail" .. tostring(m.id), "Ещё раз — удалить письмо") then return end
  K:request("mail", "delete", { id = m.id }, function(data, err)
    if not data then K:flash(err, colors.orange); return end
    for i, it in ipairs(st.items) do if it.id == m.id then table.remove(st.items, i); break end end
    st.unread = tonumber(data.unread) or st.unread
    st.view, st.msg = "list", nil
    save(K, st)
    K:flash("Письмо удалено", colors.yellow)
  end)
end

local function reply(K, st)
  local m = st.msg
  K:ask("Ответ", { max = 300, placeholder = "для " .. tostring(m.from) }, function(body)
    if not tostring(body or ""):match("[^ ]") then return end
    send(K, st, m.from, body)
  end)
end

local function do_button(K, st, act)
  if act == "back" then st.view, st.msg = "list", nil
  elseif act == "reply" then reply(K, st)
  elseif act == "delete" then delete(K, st, st.msg) end
end

local function activate(K, st, r)
  if not r then return end
  if r.act == "write" then write(K, st)
  elseif r.msg then open(K, st, r.msg) end
end

function T.key(K, st, ev, a, b, c)
  if st.view == "read" and st.msg then
    if ev == "key" then
      if a == keys.backspace or a == keys.enter then st.view, st.msg = "list", nil; return true end
      if a == keys.up or a == keys.down then st.top = (st.top or 1) + (a == keys.up and -1 or 1); return true end
      if a == keys.pageUp or a == keys.pageDown then st.top = (st.top or 1) + (a == keys.pageUp and -8 or 8); return true end
      if keys.r and a == keys.r then reply(K, st); return true end
      if a == keys.delete then delete(K, st, st.msg); return true end
    elseif ev == "mouse_scroll" then
      st.top = (st.top or 1) + a * 2; return true
    elseif ev == "mouse_click" and c == K.h - 1 then
      local x = 1
      for _, bt in ipairs(BUTTONS) do
        local bw = text.len(bt.label)
        if b >= x and b < x + bw then do_button(K, st, bt.act); return true end
        x = x + bw + 1
      end
    end
    return false
  end
  local rows = list_rows(st)
  if ev == "key" then
    if a == keys.up or a == keys.down then L.move(rows, st.lst, a == keys.up and -1 or 1); return true end
    if a == keys.pageUp or a == keys.pageDown then
      for _ = 1, 5 do L.move(rows, st.lst, a == keys.pageUp and -1 or 1) end
      return true
    end
    if a == keys.enter then activate(K, st, L.selected(rows, st.lst)); return true end
    if a == keys.delete then
      local r = L.selected(rows, st.lst)
      if r and r.msg then delete(K, st, r.msg) end
      return true
    end
    if (keys.r and a == keys.r) or (keys.f5 and a == keys.f5) then refresh(K, st, false); return true end
  elseif ev == "mouse_scroll" then
    L.move(rows, st.lst, a); return true
  elseif ev == "mouse_click" then
    local i, again = L.click(rows, st.lst, c)
    if i and again then activate(K, st, rows[i]) end
    return i ~= nil
  end
  return false
end

function T.status(K, st)
  if st.view == "read" and st.msg then
    local parts = {}
    for _, bt in ipairs(BUTTONS) do parts[#parts + 1] = bt.label end
    return table.concat(parts, " "), colors.white
  end
  if st.loading then return "запрос к капсуле..", colors.gray end
  if st.err then return "нет связи · список от " .. tostring(st.stamp or "?"), colors.orange end
  if (st.unread or 0) > 0 then return "непрочитанных: " .. st.unread, colors.yellow end
  return st.stamp and ("обновлено " .. st.stamp) or "", colors.gray
end

function T.hint(K, st)
  if st.view == "read" and st.msg then return "R — ответ · Bksp — назад" end
  return "Enter · Del · R — обновить"
end

return T
