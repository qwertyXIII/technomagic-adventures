-- tmpda.storage — вкладка «Склад» КПК: найти предмет на складе базы (МЭ-сеть и сундуки) и выдать его
-- в сундук «Выдача» на базе; внизу — что заканчивается (списки наблюдения «Склада»).
-- Запросы к приложению «Склад» капсулы: find {query} -> {items}, take {item, count} -> {text, moved…}, low -> {low}.
-- «Найти…» → что искать → результаты (сколько всего, где) → Enter → сколько выдать → «Выдано N …». R — обновить.

local L = require("tmpda.list")

local T = { id = "storage", title = "Склад", short = "Скл" }

local REFRESH = 60
local MAX_TAKE = 4096

local function fmt(n)
  n = math.floor(tonumber(n) or 0)
  if n < 10000 then return tostring(n) end
  if n < 1000000 then return math.floor(n / 1000) .. "к" end
  return math.floor(n / 1000000) .. "м"
end

function T.init(K, st)
  st.items, st.low, st.lst = {}, {}, {}
end

local function load_low(K, st, quiet)
  if st.loading then return end
  st.loading = true
  st.next = K:clock() + REFRESH
  K:request("storage", "low", {}, function(data, err)
    st.loading = false
    if type(data) ~= "table" then
      st.err = err or "нет ответа"
      if not quiet then K:flash(st.err, colors.orange) end
      return
    end
    st.err = nil
    st.low = type(data.low) == "table" and data.low or {}
  end)
end

local function find(K, st, q)
  st.query = q
  st.loading = true
  K:request("storage", "find", { query = q }, function(data, err)
    st.loading = false
    if type(data) ~= "table" then K:flash(err or "нет ответа", colors.orange); return end
    st.err = nil
    st.items = type(data.items) == "table" and data.items or {}
    st.result = nil
    st.lst.sel = nil
  end)
end

function T.show(K, st)
  if not st.next or K:clock() >= st.next then load_low(K, st, true) end
end

local function rows_of(st)
  local rows = { { text = st.query and ("Найти: " .. st.query) or "Найти...", fg = colors.lime, sel = true, act = "find" } }
  if st.result then rows[#rows + 1] = { text = st.result, wrap = true, fg = colors.yellow } end
  if #st.items > 0 then
    rows[#rows + 1] = { text = "Найдено: " .. #st.items, header = true }
    for _, it in ipairs(st.items) do
      rows[#rows + 1] = { text = tostring(it.name or it.id), right = fmt(it.total), sel = true, item = it,
        fg = (tonumber(it.total) or 0) > 0 and colors.white or colors.gray,
        sub = (it.where and it.where ~= "") and it.where or ((tonumber(it.total) or 0) > 0 and "" or "нет на складе") }
    end
  elseif st.query and not st.loading then
    rows[#rows + 1] = { text = "Ничего не нашлось.", fg = colors.gray }
  end
  if #st.low > 0 then
    rows[#rows + 1] = { text = "Заканчивается", header = true }
    for _, l in ipairs(st.low) do
      rows[#rows + 1] = { text = tostring(l.name or l.id), right = fmt(l.have) .. "/" .. fmt(l.min), fg = colors.orange }
    end
  end
  return rows
end

function T.draw(K, st, x, y, w, h)
  L.draw(function(t, ...) K:put(...) end, K.t, x, y, w, h, rows_of(st), st.lst)
end

local function take(K, st, it)
  local total = math.floor(tonumber(it.total) or 0)
  K:ask("Сколько", { max = 5, value = tostring(math.max(1, math.min(64, total))) }, function(v)
    local n = math.floor(tonumber(v) or 0)
    if n < 1 or n > MAX_TAKE then K:flash("Число от 1 до " .. MAX_TAKE, colors.orange); return end
    K:request("storage", "take", { item = it.id, count = n }, function(data, err)
      if type(data) ~= "table" then K:flash(err or "нет ответа", colors.orange); return end
      if st.result == nil and st.lst.sel then st.lst.sel = st.lst.sel + 1 end   -- строка итога встаёт выше результатов
      st.result = tostring(data.text or ("Выдано " .. tostring(data.moved or 0)))
      if tonumber(data.moved) then it.total = math.max(0, total - data.moved) end
      st.next = nil
      load_low(K, st, true)
    end)
  end)
end

local function activate(K, st, r)
  if not r then return end
  if r.act == "find" then
    K:ask("Найти", { max = 40, value = st.query or "", placeholder = "название или ID" }, function(q)
      q = tostring(q or ""):gsub("^ +", ""):gsub(" +$", "")
      if q ~= "" then find(K, st, q) end
    end)
  elseif r.item then
    take(K, st, r.item)
  end
end

function T.key(K, st, ev, a, b, c)
  local rows = rows_of(st)
  if ev == "key" then
    if a == keys.up or a == keys.down then L.move(rows, st.lst, a == keys.up and -1 or 1); return true end
    if a == keys.pageUp or a == keys.pageDown then
      for _ = 1, 5 do L.move(rows, st.lst, a == keys.pageUp and -1 or 1) end
      return true
    end
    if a == keys.enter then activate(K, st, L.selected(rows, st.lst)); return true end
    if (keys.r and a == keys.r) or (keys.f5 and a == keys.f5) then
      load_low(K, st, false)
      if st.query then find(K, st, st.query) end
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
  if st.loading then return "запрос к капсуле..", colors.gray end
  if st.err then return "нет связи со складом", colors.orange end
  return "выдача — в сундук «Выдача»", colors.lightGray
end

function T.hint(K, st) return "Enter — найти/выдать · R" end

return T
