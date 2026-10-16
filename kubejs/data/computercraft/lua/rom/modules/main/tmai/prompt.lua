-- tmai.prompt — системный промпт из шаблона /rom/tmai/persona.txt.
-- Порядок: неизменная часть (личность, правила) -> характер по слоям памяти -> память -> сводка -> заметки.
-- Стабильное начало помогает шлюзу продолжать сессию (X-Conversation-Id) и кэшировать промпт.
-- После финала Б (режим «ШТУРМАН-4») личность заменяется штатным модулем — см. lore.style().

local util = require("tmai.util")

local M = {}

local template

function M.load()
  template = util.read_file(util.ROM_DIR .. "/persona.txt") or "Ты бортовой ассистент спасательной капсулы. Отвечай по-русски кратко."
end

local function fill(tpl, vars)
  return (tpl:gsub("{{(%u+)}}", function(k) return vars[k] or "" end))
end

-- vars: NAME, STYLE, MEMORY, SUMMARY, NOTES, TOOLS
function M.build(vars)
  if not template then M.load() end
  vars.NAME = vars.NAME or "ЛОЦМАН"
  return fill(template, vars)
end

return M
