-- tmai.provider_openai — OpenAI-совместимый /v1/chat/completions с function calling:
-- шлюз заказчика (codex/gpt-6-luna), OpenRouter, LM Studio, Ollama, vLLM и т.п.
--  запрос:  { model, messages, tools = [{type="function", function={name, description, parameters}}],
--             tool_choice = "auto", max_tokens }   (stream не используем: CC отдаёт ответ целиком)
--  ответ:   choices[1].message = { content, tool_calls = [{id, function={name, arguments}}] }
--           поле message.reasoning (размышления) НИКОГДА не показываем игрокам.
--  результат инструмента: { role="tool", tool_call_id=id, content="..." }
-- Порядок сообщений: system (стабильная часть) -> история -> контекст хода -> вопрос.
-- Стабильное начало позволяет шлюзу продолжать сессию (X-Conversation-Id) и кэшировать промпт.

local json = require("tmai.json")

local P = {}

function P.headers(cfg)
  local h = { ["Content-Type"] = "application/json" }
  if cfg.api_key ~= "" then h["Authorization"] = "Bearer " .. cfg.api_key end
  return h
end

local function user_msg(cfg, name, text)
  local m = { role = "user", content = text }
  if type(name) == "string" and name ~= "" then
    if cfg.use_name_field and name:match("^[%w_%-]+$") then m.name = name:sub(1, 64)
    else m.content = "[" .. name .. "]: " .. text end
  end
  return m
end

-- history: { {role, content, name?} }, context: строка контекста хода (или nil)
function P.new(system, history, cfg)
  local msgs = { { role = "system", content = system } }
  for _, m in ipairs(history) do
    if m.role == "user" then msgs[#msgs + 1] = user_msg(cfg, m.name, m.content)
    else msgs[#msgs + 1] = { role = m.role, content = m.content } end
  end
  return { messages = msgs, cfg = cfg }
end

function P.add_user(conv, text, name, context)
  local cfg = conv.cfg
  if context and context ~= "" then
    if cfg.context_role == "user_prefix" then
      text = "[Контекст для ИИ, не от игрока]\n" .. context .. "\n[Вопрос игрока]\n" .. text
    else
      conv.messages[#conv.messages + 1] = { role = cfg.context_role == "system" and "system" or "developer", content = context }
    end
  end
  conv.messages[#conv.messages + 1] = user_msg(cfg, name, text)
end

function P.body(conv, tools, cfg)
  local model = cfg.model
  if cfg.model_effort and cfg.model_effort ~= "" and not model:find(":[%a]+$") then model = model .. ":" .. cfg.model_effort end
  local b = { model = model, messages = conv.messages, stream = false }
  b[cfg.max_tokens_field or "max_tokens"] = cfg.max_tokens
  if cfg.temperature and cfg.temperature >= 0 then b.temperature = cfg.temperature end
  if tools and #tools > 0 then
    local t = {}
    for _, tool in ipairs(tools) do
      t[#t + 1] = { type = "function", ["function"] = {
        name = tool.name, description = tool.description, parameters = tool.parameters } }
    end
    b.tools = t
    b.tool_choice = "auto"
  end
  return b
end

-- -> { text=, calls={ {id=, name=, args=table|nil, raw=string} }, finish= } | nil, err
function P.parse(data, conv)
  local ch = data.choices and data.choices[1]
  if not ch or not ch.message then
    local e = data.error and (data.error.message or json.encode(data.error)) or "пустой ответ"
    return nil, e
  end
  local msg = ch.message
  local res = { text = type(msg.content) == "string" and msg.content or "", calls = {}, finish = ch.finish_reason }
  local keep = { role = "assistant", content = msg.content or json.null }
  if msg.tool_calls and #msg.tool_calls > 0 then
    keep.tool_calls = msg.tool_calls
    for _, tc in ipairs(msg.tool_calls) do
      local f = tc["function"] or {}
      local args = json.decode(f.arguments or "{}")
      res.calls[#res.calls + 1] = { id = tc.id, name = f.name, args = args, raw = f.arguments }
    end
  end
  conv.messages[#conv.messages + 1] = keep
  return res
end

function P.add_tool_results(conv, results)
  for _, r in ipairs(results) do
    conv.messages[#conv.messages + 1] = { role = "tool", tool_call_id = r.id, content = r.content }
  end
end

return P
