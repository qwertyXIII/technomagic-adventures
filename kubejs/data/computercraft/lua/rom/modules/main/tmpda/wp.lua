-- tmpda.wp — вкладка «Метки» КПК: общие метки экипажа с расстоянием и стороной света от игрока с этим КПК.
-- Данные — у приложения «Метки» капсулы (запросы list, add_here, rename, remove); последний список хранится
-- в /tmpda/wp.json и виден без связи (координаты верны, расстояние — на момент обновления).
-- Список: «+ метка здесь», метки (ближние первыми). Enter — подробно, Delete — удалить (дважды), R — обновить.

local text = require("tmai.text")
local L = require("tmpda.list")

local T = { id = "wp", title = "Метки", short = "Мет" }

local REFRESH = 20
local KIND_FG = { home = colors.lime, mine = colors.orange, portal = colors.magenta, death = colors.red, other = colors.white }

local function save(K, st) K:save("wp", { items = st.items, pos = st.pos, stamp = st.stamp }) end

function T.init(K, st)
  local c = K:load("wp", {})
  st.items = type(c.items) == "table" and c.items or {}
  st.pos, st.stamp = c.pos, c.stamp
  st.view, st.lst, st.dst = "list", {}, {}
end

local function refresh(K, st, quiet)
  if st.loading then return end
  st.loading = true
  st.next = K:clock() + REFRESH
  K:request("wp", "list", {}, function(data, err)
    st.loading = false
    if type(data) ~= "table" then
      st.err = err or "нет ответа"
      if not quiet then K:flash(st.err, colors.orange) end
      return
    end
    -- выбор остаётся на той же метке, даже если список пересортировался (игрок идёт — расстояния меняются)
    local sel = st.lst.sel and st.lst.sel > 1 and st.items[st.lst.sel - 1]
    st.items = type(data.items) == "table" and data.items or {}
    if sel then
      for i, it in ipairs(st.items) do if it.id == sel.id then st.lst.sel = i + 1 end end
    end
    st.pos, st.pos_err, st.err = data.pos, data.pos_err, nil
    st.stamp = K:stamp()
    st.next = K:clock() + REFRESH
    save(K, st)
  end)
end
T.refresh = refresh

function T.show(K, st)
  if not st.next or K:clock() >= st.next then refresh(K, st, true) end
end

function T.tick(K)
  local st = K.st.wp
  if K:tab().id == "wp" and st.view == "list" and not K.prompt and st.next and K:clock() >= st.next then
    refresh(K, st, true)
  end
end

local function find(st, id)
  for i, it in ipairs(st.items) do if it.id == id then return it, i end end
end

local function where(it)
  local s = ("%d %d %d"):format(math.floor(tonumber(it.x) or 0), math.floor(tonumber(it.y) or 0), math.floor(tonumber(it.z) or 0))
  if it.same_dim == false then s = s .. " · " .. tostring(it.dim_name or "") end
  return s .. " · " .. tostring(it.kind_ru or "")
end

local function list_rows(st)
  local rows = { { text = "+ метка здесь", fg = colors.lime, sel = true, act = "add" } }
  for _, it in ipairs(st.items) do
    local right
    if tonumber(it.dist) then right = it.dist < 3 and "здесь" or (math.floor(it.dist) .. " " .. tostring(it.dir_s or ""))
    elseif it.same_dim == false then right = "др.изм." end
    rows[#rows + 1] = { text = tostring(it.name), right = right, fg = KIND_FG[it.kind] or colors.white, sel = true,
      item = it, sub = where(it) }
  end
  if #st.items == 0 then
    rows[#rows + 1] = { text = st.stamp and "Меток пока нет." or "Нет данных: R — обновить.", fg = colors.gray }
  end
  return rows
end

local function detail_rows(it)
  local rows = { { text = tostring(it.name), header = true } }
  local function info(s, fg) rows[#rows + 1] = { text = s, fg = fg or colors.white, wrap = true } end
  info(("X %d  Y %d  Z %d"):format(math.floor(tonumber(it.x) or 0), math.floor(tonumber(it.y) or 0), math.floor(tonumber(it.z) or 0)))
  info(tostring(it.dim_name or it.dim or ""), colors.lightGray)
  info("Вид: " .. tostring(it.kind_ru or ""), KIND_FG[it.kind])
  info("Поставил: " .. tostring(it.author or "?"), colors.lightGray)
  info("Когда: " .. tostring(it.ago or "?"), colors.lightGray)
  info(it.route and ("Вам: " .. it.route) or "Где вы — неизвестно (нет связи с модулем)", colors.yellow)
  rows[#rows + 1] = { text = "Переименовать", sel = true, act = "rename" }
  rows[#rows + 1] = { text = "Удалить", sel = true, act = "delete", fg = colors.red }
  rows[#rows + 1] = { text = "< Назад", sel = true, act = "back" }
  return rows
end

local function rows_of(st)
  if st.view == "detail" then
    local it = find(st, st.id)
    if it then return detail_rows(it), st.dst end
    st.view = "list"
  end
  return list_rows(st), st.lst
end

function T.draw(K, st, x, y, w, h)
  local rows, ls = rows_of(st)
  L.draw(function(t, ...) K:put(...) end, K.t, x, y, w, h, rows, ls)
end

local function open(st, it)
  st.view, st.id = "detail", it.id
  local rows = detail_rows(it)
  st.dst = {}
  for i, r in ipairs(rows) do if r.act == "back" then st.dst.sel = i end end
end

local function delete(K, st, it)
  if not K:confirm("wp" .. it.id, "Ещё раз — удалить «" .. tostring(it.name) .. "»") then return end
  K:request("wp", "remove", { id = it.id }, function(data, err)
    if not data then K:flash(err, colors.orange); return end
    local _, i = find(st, it.id)
    if i then table.remove(st.items, i) end
    st.view = "list"
    save(K, st)
    K:flash("Метка «" .. tostring(it.name) .. "» удалена", colors.yellow)
  end)
end

local function add_here(K, st)
  K:ask("Имя", { max = 32, placeholder = "пусто — «Метка N»" }, function(name)
    K:request("wp", "add_here", { name = name }, function(data, err)
      if not data then K:flash(err, colors.orange); return end
      K:flash(("Метка «%s»: %d %d %d"):format(tostring(data.name), math.floor(tonumber(data.x) or 0),
        math.floor(tonumber(data.y) or 0), math.floor(tonumber(data.z) or 0)), colors.lime)
      st.next = nil
      refresh(K, st, true)
    end)
  end)
end

local function rename(K, st, it)
  K:ask("Имя", { max = 32, value = it.name }, function(name)
    K:request("wp", "rename", { id = it.id, name = name }, function(data, err)
      if not data then K:flash(err, colors.orange); return end
      it.name = data.name
      save(K, st)
      K:flash("Переименовано", colors.lime)
    end)
  end)
end

local function activate(K, st, r)
  if not r then return end
  if r.act == "add" then add_here(K, st)
  elseif r.item then open(st, r.item)
  elseif r.act == "back" then st.view = "list"
  elseif r.act == "rename" then local it = find(st, st.id); if it then rename(K, st, it) end
  elseif r.act == "delete" then local it = find(st, st.id); if it then delete(K, st, it) end
  end
end

function T.key(K, st, ev, a, b, c)
  local rows, ls = rows_of(st)
  if ev == "key" then
    if a == keys.up or a == keys.down then L.move(rows, ls, a == keys.up and -1 or 1); return true end
    if a == keys.pageUp or a == keys.pageDown then
      for _ = 1, 5 do L.move(rows, ls, a == keys.pageUp and -1 or 1) end
      return true
    end
    if a == keys.enter then activate(K, st, L.selected(rows, ls)); return true end
    if a == keys.backspace and st.view == "detail" then st.view = "list"; return true end
    if a == keys.delete then
      local r = L.selected(rows, ls)
      local it = st.view == "detail" and find(st, st.id) or (r and r.item)
      if it then delete(K, st, it) end
      return true
    end
    if (keys.r and a == keys.r) or (keys.f5 and a == keys.f5) then refresh(K, st, false); return true end
  elseif ev == "mouse_scroll" then
    L.move(rows, ls, a); return true
  elseif ev == "mouse_click" then
    local i, again = L.click(rows, ls, c)
    if i and again then activate(K, st, rows[i]) end
    return i ~= nil
  end
  return false
end

function T.status(K, st)
  if st.loading then return "запрос к капсуле..", colors.gray end
  if st.err then return "нет связи · список от " .. tostring(st.stamp or "?"), colors.orange end
  if st.pos then
    return ("Вы: %d %d %d"):format(math.floor(tonumber(st.pos.x) or 0), math.floor(tonumber(st.pos.y) or 0),
      math.floor(tonumber(st.pos.z) or 0)), colors.lightGray
  end
  if st.pos_err then return "где вы — неизвестно", colors.orange end
  return st.stamp and ("обновлено " .. st.stamp) or "", colors.gray
end

function T.hint(K, st)
  if st.view == "detail" then return "Enter · Bksp — назад · Del" end
  return "Enter · Del · R — обновить"
end

return T
