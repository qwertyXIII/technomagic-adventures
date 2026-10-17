-- tmpda.list — список для экранов КПК (26×20): строки в одну или несколько линий, выбор, прокрутка, щелчок.
--   rows = { { text=, right= (справа), fg=, right_fg=, sub= (строка под ней с отступом, переносится), sub_fg=,
--             wrap=true (переносить text, а не обрезать), sel=true (можно выбрать), header=true }, … }
--   st   = { sel = номер выбранной строки, top = первая видимая линия, follow = держать выбранную на экране }
--   L.draw(put, t, x, y, w, h, rows, st)  — нарисовать (put(t, x, y, s, fg, bg) печатает UTF-8)
--   L.move(rows, st, dir) -> true, если выбор сдвинулся (иначе прокрутка на линию)
--   L.page(st, n)          — прокрутить на n линий (PgUp/PgDn, колесо)
--   L.click(st, yy) -> номер строки и было ли это повторное касание выбранной (= открыть)
--   L.selected(rows, st) -> строка или nil
-- Первая колонка — метка выбора «>», текст — с x+1. Ничего не пишется за правый край.

local text = require("tmai.text")

local L = {}

local function selectable(rows, i) local r = rows[i]; return r ~= nil and r.sel == true and not r.header end

local function layout(rows, w)
  local lines = {}
  local cw = math.max(1, w - 1)
  for i, r in ipairs(rows) do
    if r.header then
      lines[#lines + 1] = { row = i, s = text.fit(r.text, w), fg = r.fg or colors.cyan, header = true }
    else
      local first = true
      if r.wrap then
        for _, l in ipairs(text.wrap(r.text or "", cw)) do
          lines[#lines + 1] = { row = i, s = text.fit(l, cw), fg = r.fg or colors.white, first = first }
          first = false
        end
      else
        local s, rs = r.text or "", nil
        if r.right and r.right ~= "" then
          local rw = math.min(text.len(r.right), math.max(1, cw - 4))
          s = text.fit(s, math.max(0, cw - rw - 1), "..") .. " "
          rs = text.fit(r.right, rw)
        else
          s = text.fit(s, cw, "..")
        end
        lines[#lines + 1] = { row = i, s = s, rs = rs, fg = r.fg or colors.white, rfg = r.right_fg or colors.lightGray, first = true }
      end
      if r.sub and r.sub ~= "" then
        for _, l in ipairs(text.wrap(r.sub, math.max(1, cw - 1))) do
          lines[#lines + 1] = { row = i, s = text.fit(" " .. l, cw), fg = r.sub_fg or colors.lightGray }
        end
      end
    end
  end
  return lines
end

function L.fix(rows, st)
  if not selectable(rows, st.sel or 0) then
    st.sel = nil
    for i = 1, #rows do if selectable(rows, i) then st.sel = i; break end end
  end
  return st.sel
end

function L.selected(rows, st)
  L.fix(rows, st)
  return st.sel and rows[st.sel] or nil
end

function L.draw(put, t, x, y, w, h, rows, st)
  local lines = layout(rows, w)
  local sel = L.fix(rows, st)
  local top = st.top or 1
  if sel and st.follow ~= false then
    local a, b
    for i, l in ipairs(lines) do
      if l.row == sel then a = a or i; b = i end
    end
    if a then
      if b > top + h - 1 then top = b - h + 1 end
      if a < top then top = a end
    end
  end
  top = math.max(1, math.min(top, math.max(1, #lines - h + 1)))
  st.top, st.lines, st.y0, st.h = top, lines, y, h
  for i = 0, h - 1 do
    local l = lines[top + i]
    local yy = y + i
    if l then
      local on = l.row == sel and not l.header
      local bg = on and colors.gray or colors.black
      put(t, x, yy, (on and l.first) and ">" or " ", colors.yellow, bg)
      if l.header then
        put(t, x, yy, l.s, l.fg, colors.black)
      else
        put(t, x + 1, yy, l.s, l.fg, bg)
        if l.rs then put(t, x + 1 + text.len(l.s), yy, l.rs, l.rfg, bg) end
      end
    else
      put(t, x, yy, (" "):rep(w), colors.white, colors.black)
    end
  end
  return lines
end

-- Следующая выбираемая строка; нет — прокрутка на линию (чтобы дочитать длинный текст).
function L.move(rows, st, dir)
  local i = (L.fix(rows, st) or 0) + dir
  while rows[i] and not selectable(rows, i) do i = i + dir end
  st.follow = true
  if selectable(rows, i) then st.sel = i; return true end
  L.page(st, dir)
  st.follow = false
  return false
end

function L.page(st, n)
  st.top = math.max(1, (st.top or 1) + n)
  st.follow = false
end

-- Касание линии экрана yy: -> номер строки, повторное ли касание выбранной
function L.click(rows, st, yy)
  if not st.lines or not st.y0 or yy < st.y0 or yy >= st.y0 + (st.h or 0) then return nil end
  local l = st.lines[(st.top or 1) + yy - st.y0]
  if not l or not selectable(rows, l.row) then return nil end
  local again = st.sel == l.row
  st.sel, st.follow = l.row, true
  return l.row, again
end

return L
