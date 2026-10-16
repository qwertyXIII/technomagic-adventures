-- tmai.chat — обёртка над chatBox из Advanced Peripherals 0.8.x.
--
-- Факты из AdvancedPeripherals-1.21.1-0.8.2a.jar (ChatBoxPeripheral/Events):
--  * событие: "chat", uuid, username, message, isHidden, messageUtf8
--    (в 0.7.x было: "chat", username, message, uuid, isHidden) — разбираем оба;
--    message для кириллицы приходит как "????" — берём messageUtf8 (байты UTF-8);
--  * сообщения, начинающиеся с "$", скрыты из общего чата (isHidden=true);
--  * sendMessage(text, {utf8=true, prefix=, brackets="[]", bracketsColor="&b", range=, player=})
--    — player делает сообщение личным; длина проверяется в БАЙТАХ до перекодировки
--    (chatBoxMessageSize=1024), перезарядка 1000 мс на каждое сообщение (chatMessageCooldown);
--  * sendToast({title=, message=, player=, utf8=true}) — всплывающее уведомление игроку.

local u8 = require("tmai.u8")
local util = require("tmai.util")

local M = {}

local box

function M.attach()
  box = peripheral.find("chat_box")
  return box ~= nil
end

local function is_uuid(s)
  return type(s) == "string" and s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

-- ev = { "chat", ... } -> { name=, uuid=, text=, hidden= } или nil
function M.parse(ev)
  local a1, a2, a3, a4, a5 = ev[2], ev[3], ev[4], ev[5], ev[6]
  local m
  if is_uuid(a1) or (a1 == nil and type(a2) == "string" and type(a3) == "string") then
    m = { uuid = a1, name = a2, text = (type(a5) == "string" and a5) or a3, hidden = a4 == true }
  else
    m = { name = a1, text = a2, uuid = a3, hidden = a4 == true }
  end
  if type(m.name) ~= "string" or type(m.text) ~= "string" then return nil end
  return m
end

local cfg_prefix, cfg_bytes = "ИИ", 900
function M.configure(prefix, chat_bytes)
  cfg_prefix, cfg_bytes = prefix or cfg_prefix, chat_bytes or cfg_bytes
end

local function send_one(text, player)
  for attempt = 1, 8 do
    local pok, ok, err = pcall(box.sendMessage, text, {
      utf8 = true, prefix = cfg_prefix, brackets = "[]", bracketsColor = "&b", player = player,
    })
    if not pok then err = ok; ok = false end
    if ok then return true end
    err = tostring(err)
    if err:find("cooldown") then
      sleep(0.6)
    else
      util.log("W", "chat send failed: %s", err)
      return false, err
    end
  end
  return false, "cooldown"
end

-- Отправить (возможно длинный) текст: режем на куски, ждём перезарядку между ними.
-- player=nil — всем; player="Ник" — лично.
function M.say(text, player)
  if not box then return false end
  local parts = u8.chunks(u8.clean_for_chat(text), cfg_bytes)
  for i, part in ipairs(parts) do
    if i > 1 then sleep(1.05) end
    send_one(part, player)
  end
  return true
end

function M.toast(player, title, message)
  if not box or not box.sendToast then return false end
  local ok = pcall(box.sendToast, { title = title, message = message, player = player, utf8 = true,
    prefix = cfg_prefix, brackets = "[]", bracketsColor = "&b" })
  return ok
end

return M
