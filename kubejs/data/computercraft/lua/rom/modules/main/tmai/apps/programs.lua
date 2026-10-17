-- tmai.apps.programs — «Программы»: диспетчер программ, которые ЛОЦМАН написал и запустил на других компьютерах
-- и черепашках через агентов tmexec (данные и управление — tmai.scripts; задания переживают перезапуск).
-- Терминал (свой вид):
--   список — задания (код, имя, где, состояние, когда; внизу — последний вывод или ошибка выбранного) и
--     компьютеры с агентом (id, метка, черепашка/компьютер, на связи ли);
--   Enter на задании — подробности: состояние, ошибка, вывод, код программы (↑↓ PgUp/PgDn — листать) и кнопки
--     (←→ + Enter или щелчок): Запустить (= «да КОД») / Запустить снова / Остановить / Удалить / Назад.
-- Тревога «programs.<код>» — программа упала (одна на каждое падение); снимается, когда программа снова
--   работает, завершилась или удалена из списка.
-- Инструмент ИИ: programs_list — полная сводка (и компьютеры не на связи, и время, и вывод). Остальное у ИИ —
--   computers_list и script_* (tmai.tools).

local text = require("tmai.text")
local util = require("tmai.util")
local json = require("tmai.json")
local scripts = require("tmai.scripts")

local A = { id = "programs", title = "Программы", short = "Прог", order = 50, every = 5 }

local STATE = {
  proposed = { "ждёт «да»", colors.yellow }, deployed = { "ждёт «да»", colors.yellow },
  starting = { "запуск", colors.lightBlue }, running = { "работает", colors.lime },
  done = { "завершена", colors.lightGray }, error = { "упала", colors.red }, stopped = { "остановлена", colors.orange },
}
local WAIT = { proposed = true, deployed = true }
local RUN = { starting = true, running = true }

local V = { mode = "list", sel = 1, top = 1 }   -- вид терминала; mode = "list" | "job"

-- ---------------------------------------------------------------- помощники

local function state_of(j)
  local s = STATE[j.state]
  if s then return s[1], s[2] end
  return tostring(j.state or "?"), colors.white
end

local function ago(t, short)
  local d = util.now() - (tonumber(t) or 0)
  if not t or d < 0 then return "" end
  if d < 60 then return short and "сейчас" or "только что" end
  local s
  if d < 3600 then s = math.floor(d / 60) .. " мин"
  elseif d < 86400 then s = math.floor(d / 3600) .. " ч"
  else s = math.floor(d / 86400) .. " дн" end
  return short and s or (s .. " назад")
end

local function target_of(id)
  for _, t in ipairs(scripts.targets()) do if t.id == id then return t end end
  return nil
end

local function kind_ru(kind) return kind == "turtle" and "черепашка" or "компьютер" end

local function where(j)
  local t = target_of(j.target)
  local label = t and t.label ~= "" and (" " .. t.label) or ""
  return "#" .. tostring(j.target) .. label
end

-- Первая строка ошибки без пути /tmai_scripts/ (для тревоги и списка).
local function short_err(e, max)
  local s = tostring(e or "")
  s = s:match("^[^\n]*") or s
  s = s:gsub("/?tmai_scripts/", "")
  if #s > (max or 120) then s = s:sub(1, max or 120) .. "…" end
  return s
end

local function last_line(out)
  local last
  for l in (tostring(out or "") .. "\n"):gmatch("([^\n]*)\n") do
    if l:match("%S") then last = l end
  end
  return last
end

local function counts()
  local run, wait, err = 0, 0, 0
  local list = scripts.jobs()
  for _, j in ipairs(list) do
    if RUN[j.state] then run = run + 1 elseif WAIT[j.state] then wait = wait + 1 elseif j.state == "error" then err = err + 1 end
  end
  return run, wait, err, #list
end

-- ---------------------------------------------------------------- тревоги

local function check_alerts(ctx)
  local al = ctx.alert
  if not al then return end
  if type(ctx.data.raised) ~= "table" then ctx.data.raised = {} end
  local raised = ctx.data.raised
  local dirty, seen = false, {}
  for _, j in ipairs(scripts.jobs()) do
    local key = "programs." .. j.job
    seen[j.job] = true
    local stamp = tostring(j.changed or j.t or 0)
    if j.state == "error" then
      if raised[j.job] ~= stamp then      -- одна тревога на каждое падение (снятая вручную не вернётся)
        raised[j.job] = stamp
        dirty = true
        al.raise(key, ("Программа %s на #%s упала: %s"):format(tostring(j.name), tostring(j.target), short_err(j.last_error, 80)),
          { level = "warn", app = "programs" })
      end
    elseif j.state == "running" or j.state == "done" or j.state == "stopped" then
      if raised[j.job] then raised[j.job] = nil; dirty = true end
      if al.active(key) then al.clear(key, j.state == "running" and ("Программа " .. tostring(j.name) .. " снова работает.") or nil) end
    end
  end
  for code in pairs(raised) do
    if not seen[code] then raised[code] = nil; dirty = true end
  end
  for _, a in ipairs(al.list()) do
    if a.key:sub(1, 9) == "programs." and not seen[a.key:sub(10)] then al.clear(a.key) end
  end
  if dirty then ctx.save() end
end

-- ---------------------------------------------------------------- жизненный цикл

function A.init(ctx)
  V = { mode = "list", sel = 1, top = 1 }
  if type(ctx.data.raised) ~= "table" then ctx.data.raised = {} end
end

function A.tick(ctx) check_alerts(ctx) end

function A.event(ctx, name, sender, msg, proto)
  if name == "rednet_message" and proto == scripts.PROTO and type(msg) == "table" and msg.op == "status" then
    ctx.later(check_alerts, ctx)
  end
end

function A.action(ctx, act)
  local code = tostring(act.job or "")
  local j = scripts.job(code)
  if act.op == "confirm" then
    if not j then return end
    local r = scripts.confirm(code, false)
    if r then ctx.say(("Запускаю %s на компьютере #%s."):format(r.name, tostring(r.target)), "sys") end
  elseif act.op == "rerun" then
    local r, err = scripts.rerun(code)
    if r then ctx.say(("Запускаю %s снова на компьютере #%s."):format(r.name, tostring(r.target)), "sys")
    else ctx.say("Программы: " .. tostring(err), "warn") end
  elseif act.op == "stop" then
    if j and scripts.stop(code) > 0 then ctx.say("Программа " .. j.name .. " остановлена.", "sys") end
  elseif act.op == "forget" then
    if scripts.forget(code) and ctx.alert then ctx.alert.clear("programs." .. code) end
  end
  check_alerts(ctx)
end

function A.status(ctx)
  local run, wait, err, n = counts()
  local parts = {}
  if err > 0 then parts[#parts + 1] = "упала " .. err end
  if run > 0 then parts[#parts + 1] = "работает " .. run end
  if wait > 0 and #parts < 2 then parts[#parts + 1] = "ждёт " .. wait end
  if #parts > 0 then return table.concat(parts, ", ") end
  local on = #scripts.list_targets()
  if on > 0 then return "на связи: " .. on end
  if n > 0 then return "программ: " .. n end
  return nil
end

-- ---------------------------------------------------------------- нейросеть

local function obj(props, required)
  return { type = "object", properties = props, required = required or json.empty_array, additionalProperties = false }
end

function A.tools(ctx)
  if #scripts.jobs() == 0 and #scripts.targets() == 0 then return {} end
  return {
    { name = "programs_list", description = "Сводка вкладки «Программы»: все программы ЛОЦМАНа на других компьютерах (код, состояние, когда, последний вывод, ошибка) и все компьютеры с агентом tmexec, включая те, что сейчас не на связи. Код и стек упавшей — script_status.",
      parameters = obj({}) },
  }
end

function A.run_tool(ctx, name)
  if name ~= "programs_list" then return "нет такого инструмента" end
  local progs, comps = {}, {}
  for _, j in ipairs(scripts.jobs()) do
    local word = state_of(j)
    local lo = last_line(j.output)
    progs[#progs + 1] = { job = j.job, name = j.name, target = j.target, computer = where(j), state = word,
      when = ago(j.changed or j.t), description = j.description ~= "" and j.description or nil,
      last_output = lo and lo:sub(1, 200) or nil, error = j.state == "error" and short_err(j.last_error, 300) or nil,
      auto_fix = j.auto and true or nil }
  end
  for _, t in ipairs(scripts.targets()) do
    comps[#comps + 1] = { id = t.id, label = t.label, kind = kind_ru(t.kind), online = t.online, seen = ago(t.seen),
      busy = t.busy and (t.busy .. " (" .. tostring(t.busy_job) .. ")") or nil, free = t.online and not t.busy or nil }
  end
  return { programs = progs, computers = comps,
    note = "одна программа = один компьютер с tmexec: новую — на свободный (free); свободного нет — попроси игрока поставить ещё компьютер с модемом и «tmexec startup», работающую без согласия не вытесняй. Запуск — игрок: «да КОД» или кнопка во вкладке «Программы»; остановить — script_stop" }
end

-- ---------------------------------------------------------------- список (НЕ ждёт)

local function list_items()
  local items = {}
  local jobs = scripts.jobs()
  local run, wait, err = counts()
  local head = {}
  if run > 0 then head[#head + 1] = "работает " .. run end
  if wait > 0 then head[#head + 1] = "ждёт " .. wait end
  if err > 0 then head[#head + 1] = "упала " .. err end
  items[#items + 1] = { text = "Программы", right = table.concat(head, ", "), head = true }
  for _, j in ipairs(jobs) do
    local word, fg = state_of(j)
    local when = ago(j.changed or j.t, true)
    local desc
    if j.state == "error" then desc = "ошибка: " .. short_err(j.last_error)
    else
      local lo = last_line(j.output)
      desc = lo and ("вывод: " .. lo) or (j.description ~= "" and j.description or nil)
      if WAIT[j.state] then desc = "ждёт подтверждения: Enter — подробнее, кнопка «Запустить» или «да " .. j.job .. "»" end
    end
    items[#items + 1] = { text = j.job .. " " .. tostring(j.name), mid = where(j),
      right = word .. (when ~= "" and (", " .. when) or ""), rfg = fg, sel = true, job = j.job, desc = desc }
  end
  if #jobs == 0 then
    items[#items + 1] = { text = "Пока нет. Попросите ЛОЦМАНа написать программу.", fg = colors.gray }
  end
  items[#items + 1] = { text = "Компьютеры с агентом", right = "1 программа — 1 компьютер", head = true }
  local ts = scripts.targets()
  for _, t in ipairs(ts) do
    local right, rfg, desc
    if not t.online then
      right, rfg = "нет связи", colors.gray
      desc = "Молчит " .. ago(t.seen) .. ": запустите на нём tmexec (лучше «tmexec startup»)"
    elseif t.busy then
      right, rfg = "занят", colors.orange
      desc = "Работает " .. t.busy .. " (" .. tostring(t.busy_job) .. "). Одна программа — один компьютер: для новой поставьте ещё"
    else
      right, rfg = "свободен", colors.lime
      desc = "Свободен: ЛОЦМАН может записать сюда программу"
    end
    items[#items + 1] = { text = "#" .. t.id .. (t.label ~= "" and (" " .. t.label) or ""),
      mid = kind_ru(t.kind) .. (t.busy and (" · " .. t.busy) or ""), right = right, rfg = rfg, sel = true, target = t, desc = desc }
  end
  if #ts == 0 then
    items[#items + 1] = { text = "Нет. На компьютере или черепашке: tmexec startup", fg = colors.gray }
  end
  return items
end

local function selectable(items, i) return items[i] ~= nil and items[i].sel end

local function key_of(it) return it and (it.job or (it.target and ("#" .. it.target.id))) or nil end

-- Выбор держится за задание/компьютер (новые задания встают сверху и не сбивают его).
local function fix_sel(items)
  local s = V.sel or 1
  if V.key and key_of(items[s]) ~= V.key then
    for i = 1, #items do if key_of(items[i]) == V.key then s = i; break end end
  end
  if not selectable(items, s) then
    s = nil
    for i = 1, #items do if selectable(items, i) then s = i; break end end
    s = s or 1
  end
  V.sel, V.key = s, key_of(items[s])
  return s
end

local function set_sel(items, s)
  V.sel, V.key = s, key_of(items[s])
end

local function move_sel(items, dir, steps)
  local s = fix_sel(items)
  for _ = 1, steps or 1 do
    local i = s + dir
    while items[i] and not selectable(items, i) do i = i + dir end
    if selectable(items, i) then s = i else break end
  end
  set_sel(items, s)
end

-- Строка списка ровно в ширину w: «> текст   где   состояние».
local function draw_row(ctx, t, x, yy, w, it, cur, rcol)
  if it.head then
    local r = it.right or ""
    local rl = (r ~= "" and text.len(r) + 2 < w - 6) and text.len(r) or 0
    ctx.put(t, x, yy, text.fit(it.text, w - (rl > 0 and rl + 1 or 0), ".."), colors.cyan, colors.black)
    if rl > 0 then ctx.put(t, x + w - rl - 1, yy, " " .. r, colors.lightGray, colors.black) end
    return
  end
  local bg = cur and colors.gray or colors.black
  local prefix = it.sel and (cur and "> " or "  ") or "  "
  local rw = it.right and math.min(w - 3, math.max(text.len(it.right), rcol or 0)) or 0
  local rest = w - 2 - (rw > 0 and rw + 1 or 0)
  local mw = 0
  if it.mid and rest >= 18 then mw = math.min(text.len(it.mid), math.floor(rest * 0.5)) end
  local nw = rest - (mw > 0 and mw + 1 or 0)
  if nw < 1 then nw, mw, rw = math.max(1, w - 2), 0, 0 end
  ctx.put(t, x, yy, prefix .. text.fit(it.text, nw, ".."), it.fg or colors.white, bg)
  local xx = x + 2 + nw
  if mw > 0 then ctx.put(t, xx, yy, " " .. text.fit(it.mid, mw, ".."), colors.lightGray, bg); xx = xx + mw + 1 end
  if rw > 0 then ctx.put(t, xx, yy, " " .. text.fit(it.right, rw), it.rfg or colors.white, bg) end
end

local function draw_list(ctx, t, x, y, w, h)
  local items = list_items()
  local sel = fix_sel(items)
  local rows = math.max(1, h - 1)
  local top = V.top or 1
  if sel < top then top = sel end
  if sel > top + rows - 1 then top = sel - rows + 1 end
  -- заголовок раздела над выбранной строкой — тоже в окне
  if top > 1 and items[top - 1] and items[top - 1].head and sel - (top - 1) < rows then top = top - 1 end
  top = math.max(1, math.min(top, math.max(1, #items - rows + 1)))
  V.top = top
  local rcol, rcol_t = 0, 0
  for _, it in ipairs(items) do
    if it.job and it.right then rcol = math.max(rcol, text.len(it.right)) end
    if it.target and it.right then rcol_t = math.max(rcol_t, text.len(it.right)) end
  end
  for i = top, math.min(#items, top + rows - 1) do
    local it = items[i]
    draw_row(ctx, t, x, y + i - top, w, it, i == sel and it.sel, (it.job and rcol) or (it.target and rcol_t) or nil)
  end
  local it = items[sel]
  local d = V.err or (it and it.sel and it.desc) or ""
  ctx.put(t, x, y + h - 1, text.fit(d, w, ".."), V.err and colors.orange or colors.lightGray, colors.black)
end

-- ---------------------------------------------------------------- подробности задания (НЕ ждёт)

-- Жёсткий перенос (код и вывод: отступы сохраняются).
local function hard_wrap(line, w, out, fg)
  line = tostring(line):gsub("\r", ""):gsub("\t", "  ")
  if text.len(line) <= w then out[#out + 1] = { s = line, fg = fg }; return end
  local cur, n = {}, 0
  for _, ch in ipairs(text.chars(line)) do
    local cw = text.len(ch)
    if n + cw > w and n > 0 then out[#out + 1] = { s = table.concat(cur), fg = fg }; cur, n = {}, 0 end
    cur[#cur + 1] = ch
    n = n + cw
  end
  if #cur > 0 then out[#out + 1] = { s = table.concat(cur), fg = fg } end
end

local function body_lines(j, w)
  local key = j.job .. "|" .. tostring(j.changed) .. "|" .. tostring(j.state) .. "|" .. w
  if V.cache and V.cache.key == key then return V.cache.lines end
  local out = {}
  local function head(s) out[#out + 1] = { s = s, fg = colors.cyan } end
  if j.description and j.description ~= "" then
    for _, l in ipairs(text.wrap(j.description, w)) do out[#out + 1] = { s = l, fg = colors.white } end
  end
  if j.state == "error" and j.last_error then
    head("Ошибка:")
    for l in (tostring(j.last_error) .. "\n"):gmatch("([^\n]*)\n") do hard_wrap(l, w, out, colors.red) end
  end
  if j.output and tostring(j.output):match("%S") then
    head("Вывод (последние строки):")
    for l in (tostring(j.output) .. "\n"):gmatch("([^\n]*)\n") do hard_wrap(l, w, out, colors.white) end
  end
  head("Код: /tmai_scripts/" .. tostring(j.name) .. ".lua")
  local code = tostring(j.code_text or "")
  if code == "" then out[#out + 1] = { s = "(нет)", fg = colors.gray } end
  for l in (code:gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do hard_wrap(l, w, out, colors.lightGray) end
  V.cache = { key = key, lines = out }
  return out
end

local function buttons(j)
  local b = {}
  if WAIT[j.state] then b[#b + 1] = { "Запустить", "confirm" }
  elseif RUN[j.state] then b[#b + 1] = { "Остановить", "stop" }
  else b[#b + 1] = { "Запустить снова", "rerun" } end
  b[#b + 1] = { V.arm and "Точно удалить?" or "Удалить", "forget" }
  b[#b + 1] = { "Назад", "back" }
  return b
end

local function draw_job(ctx, t, x, y, w, h, j)
  local word, fg = state_of(j)
  local tg = target_of(j.target)
  local title = j.job .. " " .. tostring(j.name) .. " · " .. where(j) .. (tg and (" (" .. kind_ru(tg.kind) .. ")") or "")
  ctx.put(t, x, y, text.fit(title, w, ".."), colors.cyan, colors.black)
  local info = word .. " · " .. ago(j.changed or j.t)
  if j.player then info = info .. " · просил " .. tostring(j.player) end
  if j.auto then info = info .. " · автоисправление " .. tostring(j.fixes or 0) .. "/3" end
  if WAIT[j.state] and tg and tg.busy and tg.busy_job ~= j.job then
    info = "запуск остановит работающую там " .. tg.busy .. " · " .. info
    fg = colors.orange
  end
  if h >= 2 then ctx.put(t, x, y + 1, text.fit(info, w, ".."), fg, colors.black) end
  -- кнопки
  local bs = buttons(j)
  if not V.btn or V.btn > #bs then V.btn = 1 end
  V.zones = {}
  local xx = x
  if h >= 3 then
    ctx.bar(t, x, y + 2, w, colors.black)
    for i, b in ipairs(bs) do
      local label = "[" .. b[1] .. "]"
      local lw = text.len(label)
      if xx + lw - 1 > x + w - 1 then break end
      local on = i == V.btn
      local bfg = on and colors.black or colors.white
      local bbg = on and (b[2] == "forget" and colors.red or colors.cyan) or colors.gray
      ctx.put(t, xx, y + 2, label, bfg, bbg)
      V.zones[#V.zones + 1] = { x0 = xx, x1 = xx + lw - 1, y = y + 2, i = i }
      xx = xx + lw + 1
    end
  end
  -- текст
  local lines = body_lines(j, w)
  local rows = math.max(0, h - 4)
  V.rows = rows
  local top = math.max(1, math.min(V.dtop or 1, math.max(1, #lines - rows + 1)))
  V.dtop = top
  for i = 0, rows - 1 do
    local l = lines[top + i]
    if l then ctx.put(t, x, y + 3 + i, text.fit(l.s, w), l.fg, colors.black) end
  end
  if h >= 4 then
    local foot
    if V.arm then foot = "Enter — убрать из списка (файл на компьютере останется) · ←→ — отмена"
    elseif #lines > rows then foot = ("строки %d–%d из %d · PgUp/PgDn"):format(top, math.min(#lines, top + rows - 1), #lines)
    else foot = "" end
    ctx.put(t, x, y + h - 1, text.fit(foot, w, ".."), V.arm and colors.orange or colors.gray, colors.black)
  end
end

-- Монитор (вкладка там не показывается, но может быть открыта): краткая сводка без выбора.
local function draw_summary(ctx, t, x, y, w, h)
  local yy = y
  for _, j in ipairs(scripts.jobs()) do
    if yy > y + h - 1 then break end
    local word, fg = state_of(j)
    local wl = text.len(word)
    if w > wl + 4 then
      ctx.put(t, x, yy, text.fit(j.job .. " " .. tostring(j.name), w - wl - 1, ".."), colors.white, colors.black)
      ctx.put(t, x + w - wl, yy, word, fg, colors.black)
    else
      ctx.put(t, x, yy, text.fit(word, w), fg, colors.black)
    end
    yy = yy + 1
  end
  if yy == y then ctx.put(t, x, y, text.fit("Программ нет", w), colors.gray, colors.black) end
end

-- ---------------------------------------------------------------- договор приложения: draw/key/hint

local function open_job(code, arm)
  V.mode, V.job, V.dtop, V.btn, V.arm, V.cache = "job", code, 1, 1, nil, nil
  if arm then V.arm = true; V.btn = 2 end
end

function A.draw(ctx, t, x, y, w, h, where_)
  if where_ == "monitor" then draw_summary(ctx, t, x, y, w, h); return end
  V.area = { x = x, y = y, w = w, h = h }
  if V.mode == "job" then
    local j = scripts.job(V.job)
    if j then
      local r = {}
      for k, v in pairs(j) do r[k] = v end
      r.job = V.job
      draw_job(ctx, t, x, y, w, h, r)
      return
    end
    V.mode = "list"
  end
  draw_list(ctx, t, x, y, w, h)
end

local function press(i)
  local j = scripts.job(V.job)
  if not j then V.mode = "list"; return nil end
  local r = {}
  for k, v in pairs(j) do r[k] = v end
  local b = buttons(r)[i]
  if not b then return nil end
  local op = b[2]
  if op == "back" then V.mode, V.arm = "list", nil; return nil end
  if op == "forget" then
    if not V.arm then V.arm = true; return nil end
    local code = V.job
    V.mode, V.arm = "list", nil
    return { op = "forget", job = code }
  end
  V.arm = nil
  return { op = op, job = V.job }
end

function A.key(ctx, ev, a, b, c)
  if V.mode == "job" then
    local rows = math.max(1, V.rows or 10)
    if ev == "key" then
      if a == keys.left or a == keys.right then
        local n = 3
        V.btn = ((V.btn or 1) - 1 + (a == keys.left and -1 or 1)) % n + 1
        V.arm = nil
      elseif a == keys.enter then return true, press(V.btn or 1)
      elseif a == keys.backspace then V.mode, V.arm = "list", nil
      elseif a == keys.delete then
        if V.arm and V.btn == 2 then return true, press(2) end
        V.btn, V.arm = 2, true
      elseif a == keys.up then V.dtop = (V.dtop or 1) - 1
      elseif a == keys.down then V.dtop = (V.dtop or 1) + 1
      elseif a == keys.pageUp then V.dtop = (V.dtop or 1) - (rows - 1)
      elseif a == keys.pageDown then V.dtop = (V.dtop or 1) + (rows - 1)
      elseif a == keys.home then V.dtop = 1
      else return false end
      return true
    elseif ev == "mouse_scroll" then
      V.dtop = (V.dtop or 1) + (a > 0 and 2 or -2)
      return true
    elseif ev == "mouse_click" then
      for _, z in ipairs(V.zones or {}) do
        if c == z.y and b >= z.x0 and b <= z.x1 then
          if z.i ~= V.btn then V.arm = nil end
          V.btn = z.i
          return true, press(z.i)
        end
      end
    end
    return false
  end
  -- список
  local items = list_items()
  local rows = math.max(1, ((V.area and V.area.h) or 16) - 1)
  if ev == "key" then
    V.err = nil
    if a == keys.up then move_sel(items, -1)
    elseif a == keys.down then move_sel(items, 1)
    elseif a == keys.pageUp then move_sel(items, -1, rows - 1)
    elseif a == keys.pageDown then move_sel(items, 1, rows - 1)
    elseif a == keys.home then V.sel, V.key = 1, nil; fix_sel(items)
    elseif a == keys.enter or a == keys.delete then
      local it = items[fix_sel(items)]
      if it and it.job then open_job(it.job, a == keys.delete)
      elseif it and it.target and a == keys.enter then
        V.err = "Попросите ЛОЦМАНа: «напиши программу для #" .. it.target.id .. ", чтобы…»"
      end
    else return false end
    return true
  elseif ev == "mouse_scroll" then
    move_sel(items, a > 0 and 1 or -1)
    return true
  elseif ev == "mouse_click" and V.area then
    local ar = V.area
    local i = (V.top or 1) + (c - ar.y)
    if c >= ar.y and c < ar.y + ar.h - 1 and b >= ar.x and b < ar.x + ar.w and selectable(items, i) then
      if V.sel == i and items[i].job then open_job(items[i].job) else set_sel(items, i) end
      return true
    end
  end
  return false
end

function A.hint(ctx)
  if V.mode == "job" then return "←→ Enter — кнопки · ↑↓ — листать · Bksp — назад" end
  local items = list_items()
  local it = items[V.sel or 0]
  if it and it.job then return "Enter — подробнее и действия · Delete — удалить" end
  return "↑↓ — выбор"
end

return A
