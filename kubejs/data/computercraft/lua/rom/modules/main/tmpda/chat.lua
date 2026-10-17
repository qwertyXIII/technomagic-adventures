-- tmpda.chat — вкладка «Чат» КПК: вопрос ЛОЦМАНу, ответы и объявления капсулы (лента хранится в /tmpda/feed.json).
-- Строка ввода внизу; «exit» / «выход» — выйти из программы; PgUp/PgDn и колесо — листать.

local text = require("tmai.text")
local input = require("tmai.input")

local T = { id = "chat", title = "Чат", short = "Чат" }

local MAX = 80
local WAIT = 180          -- с: сколько ждать ответа на вопрос
local NAME_FG = { user = colors.yellow, ai = colors.cyan, sys = colors.lightGray, warn = colors.orange }

local function add(K, kind, who, s)
  local st = K.st.chat
  st.feed[#st.feed + 1] = { kind = kind, who = who, text = tostring(s or "") }
  while #st.feed > MAX do table.remove(st.feed, 1) end
  st.version = st.version + 1
  K:save("feed", st.feed)
  if K:tab().id ~= "chat" then st.unseen = true end
end
T.add = add

function T.init(K, st)
  st.feed = K:load("feed", {})
  st.version, st.scroll = 0, 0
  st.ed = input.new({ term = K.t, x = 1, y = K.h, width = K.w, prompt = "> ", max = 400, history = true,
    prompt_fg = colors.yellow, placeholder = "Вопрос Лоцману…" })
  if #st.feed == 0 then add(K, "sys", "КПК", "Связь с капсулой по радио. Пишите вопрос и Enter. Tab — вкладки.") end
end

function T.show(K, st) st.unseen = false end

function T.badge(K, st) return st.unseen and colors.yellow or nil end

local function lines(st, w)
  if st.cache and st.cache.version == st.version and st.cache.w == w then return st.cache.lines end
  local out = {}
  for _, it in ipairs(st.feed) do
    local head = tostring(it.who or "?") .. ": "
    for i, l in ipairs(text.wrap(head .. text.clean(it.text), w)) do
      out[#out + 1] = { s = l, kind = it.kind, head = i == 1 and math.min(text.len(head), text.len(l)) or 0 }
    end
  end
  st.cache = { version = st.version, w = w, lines = out }
  return out
end

function T.draw(K, st, x, y, w, h)
  local all = lines(st, w)
  st.scroll = math.max(0, math.min(st.scroll or 0, math.max(0, #all - h)))
  local last = #all - st.scroll
  local first = math.max(1, last - h + 1)
  local yy = y + h - (last - first + 1)
  for i = first, last do
    local l = all[i]
    if l.head > 0 then
      K:put(x, yy, text.sub(l.s, 1, l.head), NAME_FG[l.kind] or colors.white, colors.black)
      K:put(x + l.head, yy, text.sub(l.s, l.head + 1), colors.white)
    else
      K:put(x, yy, l.s, colors.white, colors.black)
    end
    yy = yy + 1
  end
end

function T.status(K, st)
  if (st.scroll or 0) > 0 then return "PgDn — к последним", colors.gray end
  return "Вы: " .. tostring(K.name) .. " · Tab — вкладки", colors.gray
end

function T.bottom(K, st) st.ed:move(1, K.h, K.w); st.ed:draw() end

-- Ответ капсулы и объявления.
function T.radio(K, id, m)
  local st = K.st.chat
  if m.op == "answer" then
    st.waiting = nil
    add(K, "ai", m.from or "ЛОЦМАН", m.text)
    st.scroll = 0
  elseif m.op == "notify" then
    local kind = (m.level == "warn" or m.level == "crit") and "warn" or "ai"
    add(K, kind, m.from or "ЛОЦМАН", m.text)
    st.scroll = 0
  end
end

function T.tick(K)
  local st = K.st.chat
  if st.waiting and K:clock() > st.waiting then
    st.waiting = nil
    K.link = "нет связи"
    add(K, "warn", "КПК", "Нет ответа: капсула вне зоны связи или занята.")
  end
end

function T.key(K, st, ev, a, b, c)
  if ev == "mouse_scroll" or (ev == "key" and (a == keys.pageUp or a == keys.pageDown)) then
    local up = (ev == "mouse_scroll" and a < 0) or (ev == "key" and a == keys.pageUp)
    st.scroll = math.max(0, (st.scroll or 0) + (up and 3 or -3))
    return true
  end
  local r, s = st.ed:handle(ev, a, b, c)
  if r == "submit" and s and s:match("[^ ]") then
    if s == "exit" or s == "выход" then return "exit" end
    add(K, "user", K.name, s)
    K:send({ op = "ask", player = K.name, text = s })
    st.waiting = K:clock() + WAIT
    st.scroll = 0
    return true
  end
  return r ~= nil
end

return T
