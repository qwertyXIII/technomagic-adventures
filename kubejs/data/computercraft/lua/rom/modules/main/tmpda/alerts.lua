-- tmpda.alerts — вкладка «Тревоги» КПК: объявления капсулы с уровнем warn/crit (энергия, склад, база…),
-- последние сверху, со временем в мире. Хранятся на КПК (/tmpda/alerts.json, до 50). Delete — убрать одну,
-- «Очистить всё» внизу — все (Enter дважды). Новая тревога, пока вкладка не открыта, — «*» (красная — критическая).

local L = require("tmpda.list")

local T = { id = "alerts", title = "Тревоги", short = "Трев" }

local MAX = 50

function T.init(K, st)
  local c = K:load("alerts", {})
  st.items = type(c) == "table" and c or {}
  st.lst = {}
end

function T.notify(K, m)
  if m.level ~= "warn" and m.level ~= "crit" then return end
  local st = K.st.alerts
  table.insert(st.items, 1, { text = tostring(m.text or ""), level = m.level, from = m.from, stamp = K:stamp() })
  while #st.items > MAX do table.remove(st.items) end
  K:save("alerts", st.items)
  if K:tab().id ~= "alerts" then
    st.unseen = true
    st.crit = st.crit or m.level == "crit"
  end
  st.lst.sel = nil
end

function T.show(K, st) st.unseen, st.crit = false, false end

function T.badge(K, st)
  if not st.unseen then return nil end
  return st.crit and colors.red or colors.yellow
end

local function rows_of(st)
  local rows = {}
  for i, a in ipairs(st.items) do
    local crit = a.level == "crit"
    rows[#rows + 1] = { text = (crit and "!! " or "! ") .. tostring(a.stamp or ""), fg = crit and colors.red or colors.orange,
      sub = a.text, sub_fg = colors.white, sel = true, i = i }
  end
  if #st.items == 0 then
    rows[#rows + 1] = { text = "Тревог нет.", fg = colors.gray }
  else
    rows[#rows + 1] = { text = "Очистить всё", fg = colors.lightGray, sel = true, act = "clear" }
  end
  return rows
end

function T.draw(K, st, x, y, w, h)
  L.draw(function(t, ...) K:put(...) end, K.t, x, y, w, h, rows_of(st), st.lst)
end

local function activate(K, st, r)
  if r and r.act == "clear" and K:confirm("alerts_clear", "Enter ещё раз — очистить всё") then
    st.items = {}
    K:save("alerts", st.items)
  end
end

function T.key(K, st, ev, a, b, c)
  local rows = rows_of(st)
  if ev == "key" then
    if a == keys.up or a == keys.down then L.move(rows, st.lst, a == keys.up and -1 or 1); return true end
    if a == keys.pageUp or a == keys.pageDown then
      for _ = 1, 4 do L.move(rows, st.lst, a == keys.pageUp and -1 or 1) end
      return true
    end
    if a == keys.enter then activate(K, st, L.selected(rows, st.lst)); return true end
    if a == keys.delete then
      local r = L.selected(rows, st.lst)
      if r and r.i then table.remove(st.items, r.i); K:save("alerts", st.items) end
      return true
    end
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
  local n = #st.items
  return n > 0 and ("тревог в журнале: " .. n) or "", colors.lightGray
end

function T.hint(K, st) return "↑↓ · Del — убрать" end

return T
