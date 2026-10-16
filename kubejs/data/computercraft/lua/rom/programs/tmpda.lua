-- tmpda — приложение «КПК»: разговор с ЛОЦМАНом вдали от капсулы.
-- Карманный компьютер с беспроводным модемом (дальность мала у земли и растёт с высотой; вышки продлевают)
-- или с эндер-модемом (без ограничений, из любых измерений). Вопросы уходят по rednet (протокол tmai_radio)
-- на компьютер капсулы; ответ показывается на экране (транслитом — шрифт CC не рисует кириллицу) и приходит
-- лично в чат игры. С апгрейдом «динамик» КПК проигрывает озвучку, если она включена у капсулы.
-- Вопрос можно набирать латиницей (транслитом): ЛОЦМАН поймёт.
local NAME = settings.get("tmpda.player") or ""
if NAME == "" then
  write("Your nickname: "); NAME = read()
  settings.set("tmpda.player", NAME); settings.save()
end
local opened = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.hasType(n, "modem") then rednet.open(n); opened = true end
end
if not opened then printError("No modem in this KPK (craft it with a wireless modem)"); return end
local speaker = peripheral.find("speaker")
local AI = settings.get("tmpda.ai_id")

local TR = { ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "g", ["д"] = "d", ["е"] = "e", ["ё"] = "e", ["ж"] = "zh", ["з"] = "z",
  ["и"] = "i", ["й"] = "j", ["к"] = "k", ["л"] = "l", ["м"] = "m", ["н"] = "n", ["о"] = "o", ["п"] = "p", ["р"] = "r", ["с"] = "s",
  ["т"] = "t", ["у"] = "u", ["ф"] = "f", ["х"] = "h", ["ц"] = "c", ["ч"] = "ch", ["ш"] = "sh", ["щ"] = "sch", ["ъ"] = "", ["ы"] = "y",
  ["ь"] = "'", ["э"] = "e", ["ю"] = "yu", ["я"] = "ya", ["«"] = "\"", ["»"] = "\"", ["—"] = "-", ["…"] = "..." }
local function translit(s)
  local u8 = require("tmai.u8")
  local out = {}
  local ok = pcall(function()
    for _, cp in utf8.codes(s) do
      local ch = utf8.char(cp)
      local low = u8.lower(ch)
      local t = TR[low]
      if t then out[#out + 1] = (low ~= ch and #t > 0) and (t:sub(1, 1):upper() .. t:sub(2)) or t
      elseif cp < 128 then out[#out + 1] = ch
      else out[#out + 1] = "?" end
    end
  end)
  return ok and table.concat(out) or s
end

local function play(data)
  if not speaker then return end
  local chunk = {}
  for i = 1, #data do chunk[i] = data:byte(i) - 128 end
  while not speaker.playAudio(chunk) do os.pullEvent("speaker_audio_empty") end
end

term.clear(); term.setCursorPos(1, 1)
term.setTextColor(colors.cyan); print("KPK: svyaz' s kapsuloj"); term.setTextColor(colors.white)
print("Pishite vopros (translitom). exit - vyhod.")
while true do
  term.setTextColor(colors.yellow); write("> "); term.setTextColor(colors.white)
  local q = read()
  if q == "exit" then return end
  if q ~= "" then
    local msg = { op = "ask", player = NAME, text = q }
    if AI then rednet.send(AI, msg, "tmai_radio") else rednet.broadcast(msg, "tmai_radio") end
    print("...")
    local deadline = os.clock() + 180
    local answered = false
    while os.clock() < deadline do
      local id, m = rednet.receive("tmai_radio", deadline - os.clock())
      if not id then break end
      if type(m) == "table" and m.op == "answer" then
        if not AI then AI = id; settings.set("tmpda.ai_id", id); settings.save() end
        term.setTextColor(colors.lightBlue); print(translit(tostring(m.text))); term.setTextColor(colors.white)
        answered = true
        if not speaker then break end
        deadline = os.clock() + 20   -- немного подождать звук
      elseif type(m) == "table" and m.op == "audio" and type(m.data) == "string" then
        play(m.data)
      end
    end
    if not answered then term.setTextColor(colors.red); print("[net signala]"); term.setTextColor(colors.white) end
  end
end
