-- tmai.provider_anthropic — Anthropic Messages API (POST https://api.anthropic.com/v1/messages).
-- Необязательный путь; основной — OpenAI-совместимый.
--  заголовки: x-api-key, anthropic-version: 2023-06-01
--  запрос: { model, max_tokens, system, messages, tools = [{name, description, input_schema}] }
--  ответ:  content = [{type="text", text}, {type="tool_use", id, name, input}], stop_reason
--  результаты инструментов — одним user-сообщением: [{type="tool_result", tool_use_id, content}]
-- Для Claude Haiku/Opus 5.x: параметр thinking не передавать; задержку ответа регулирует
-- output_config.effort ("low" для чата) — через tmai.extra_body.

local P = {}

function P.headers(cfg)
  return { ["Content-Type"] = "application/json", ["x-api-key"] = cfg.api_key,
    ["anthropic-version"] = "2023-06-01" }
end

function P.new(system, history, cfg)
  local msgs = {}
  for _, m in ipairs(history) do
    local content = m.content
    if m.role == "user" and m.name then content = "[" .. m.name .. "]: " .. content end
    msgs[#msgs + 1] = { role = m.role, content = content }
  end
  return { system = system, messages = msgs }
end

-- Контекст хода — отдельным текстовым блоком в том же user-сообщении (после истории).
function P.add_user(conv, text, name, context)
  local blocks = {}
  if context and context ~= "" then blocks[#blocks + 1] = { type = "text", text = "[Контекст для ИИ, не от игрока]\n" .. context } end
  blocks[#blocks + 1] = { type = "text", text = (name and ("[" .. name .. "]: ") or "") .. text }
  conv.messages[#conv.messages + 1] = { role = "user", content = blocks }
end

function P.body(conv, tools, cfg)
  local b = { model = cfg.model, max_tokens = cfg.max_tokens, system = conv.system, messages = conv.messages }
  if tools and #tools > 0 then
    local t = {}
    for _, tool in ipairs(tools) do
      t[#t + 1] = { name = tool.name, description = tool.description, input_schema = tool.parameters }
    end
    b.tools = t
  end
  return b
end

function P.parse(data, conv)
  if data.type == "error" or not data.content then
    return nil, data.error and data.error.message or "пустой ответ"
  end
  local res = { text = "", calls = {}, finish = data.stop_reason }
  local texts = {}
  for _, block in ipairs(data.content) do
    if block.type == "text" then texts[#texts + 1] = block.text
    elseif block.type == "tool_use" then
      res.calls[#res.calls + 1] = { id = block.id, name = block.name, args = block.input or {} }
    end
  end
  res.text = table.concat(texts, "\n")
  if data.stop_reason == "refusal" then res.text = res.text ~= "" and res.text or "[запрос отклонён фильтром]" end
  -- ассистентский ход возвращаем целиком (включая thinking/tool_use блоки), без правок
  conv.messages[#conv.messages + 1] = { role = "assistant", content = data.content }
  return res
end

function P.add_tool_results(conv, results)
  local blocks = {}
  for _, r in ipairs(results) do
    blocks[#blocks + 1] = { type = "tool_result", tool_use_id = r.id, content = r.content, is_error = r.is_error or nil }
  end
  conv.messages[#conv.messages + 1] = { role = "user", content = blocks }
end

return P
