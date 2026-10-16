-- tmai.ui — экран состояния на терминале компьютера и на мониторе (если есть).
-- CC-шрифт кириллицу не рисует: на экране только латиница/транслит и цифры.

local M = {}

local lines = {}

function M.log_line(s)
  lines[#lines + 1] = os.date and (textutils.formatTime(os.time(), true) .. " " .. s) or s
  while #lines > 30 do table.remove(lines, 1) end
end

local function draw(t, info)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  t.setTextColor(colors.cyan)
  t.write("TM-AI  LOCMAN  onboard assistant SK-4")
  local y = 2
  local function row(label, value, color)
    if y > h then return end
    t.setCursorPos(1, y)
    t.setTextColor(colors.lightGray); t.write(label)
    t.setTextColor(color or colors.white); t.write(tostring(value))
    y = y + 1
  end
  local p = info.power or {}
  row("POWER  ", p.energy and (p.pct .. "% " .. p.energy .. " FE" .. (p.far and " CORE NOT ADJACENT" or "")) or "no core",
    p.ok and colors.lime or colors.red)
  row("LLM    ", info.llm or "?", info.llm_ok and colors.lime or colors.orange)
  row("TOOLS  ", info.tools or "-")
  row("SEARCH ", info.search or "keywords")
  row("ME     ", info.me and "online" or "offline", info.me and colors.lime or colors.gray)
  row("NAV    ", info.nav and ("repair " .. (info.repair or 0) .. "/4") or "no link", info.nav and colors.lime or colors.gray)
  row("RADIO  ", info.radio or "?")
  row("QUEUE  ", info.queue or 0)
  y = y + 1
  t.setTextColor(colors.gray)
  local start = math.max(1, #lines - (h - y))
  for i = start, #lines do
    if y > h then break end
    t.setCursorPos(1, y); t.write(lines[i]:sub(1, w)); y = y + 1
  end
end

function M.render(info)
  draw(term, info)
  local mon = peripheral.find("monitor")
  if mon then
    pcall(mon.setTextScale, 0.5)
    pcall(draw, mon, info)
  end
end

return M
