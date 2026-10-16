-- tmai.llm — один «вопрос -> ответ» с циклом вызова инструментов.
-- Не зависит от провайдера: формат запроса/ответа — в provider_openai / provider_anthropic.

local json = require("tmai.json")
local util = require("tmai.util")

local M = {}

local providers = {
  openai = require("tmai.provider_openai"),
  anthropic = require("tmai.provider_anthropic"),
}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then merge(dst[k], v) else dst[k] = v end
  end
end

-- HTTP POST JSON -> decoded table | nil, err, code, retry_after
-- http.post({...}) в CC: Tweaked — обёртка над асинхронным http.request: корутина ждёт
-- http_success/http_failure, остальные корутины программы (чат, экран) продолжают работать.
function M.post_json(url, body_tbl, headers, timeout)
  local body = json.encode(body_tbl)
  local res, err, fail = http.post({ url = url, body = body, headers = headers, binary = true, timeout = timeout })
  if not res then
    local detail, code, retry = tostring(err), nil, nil
    if fail then
      code = fail.getResponseCode and fail.getResponseCode() or nil
      local h = fail.getResponseHeaders and fail.getResponseHeaders() or {}
      retry = tonumber(h["Retry-After"] or h["retry-after"] or "")
      local text = fail.readAll() or ""
      fail.close()
      local d = json.decode(text)
      local msg = d and d.error and (d.error.message or d.error.code or tostring(d.error)) or text:sub(1, 300)
      detail = "HTTP " .. tostring(code) .. ": " .. tostring(msg)
    end
    return nil, detail, code, retry
  end
  local text = res.readAll()
  res.close()
  local data, jerr = json.decode(text)
  if not data then return nil, "не JSON: " .. tostring(jerr) end
  return data
end

local function prepare(cfg, conv, tools, P, conv_id)
  local body = P.body(conv, tools, cfg)
  if cfg.extra_body ~= "" then
    local extra = json.decode(cfg.extra_body)
    if type(extra) == "table" then merge(body, extra) end
  end
  local headers = P.headers(cfg)
  if cfg.extra_headers ~= "" then
    local extra = json.decode(cfg.extra_headers)
    if type(extra) == "table" then for k, v in pairs(extra) do headers[k] = tostring(v) end end
  end
  if conv_id and cfg.conversation_header and cfg.conversation_header ~= "" then
    headers[cfg.conversation_header] = conv_id
  end
  return body, headers
end

-- POST с повторами: 429 — ждём Retry-After (не дольше 30 с), 502/503/504 — короткая пауза.
local function post_retry(cfg, url, body, headers)
  local data, err, code, retry
  for attempt = 0, (cfg.retries or 2) do
    data, err, code, retry = M.post_json(url, body, headers, cfg.timeout)
    if data then return data end
    if code == 429 then sleep(math.min(retry or 5, 30))
    elseif code == 502 or code == 503 or code == 504 or code == nil then sleep(2 + attempt * 3)
    else break end
  end
  return nil, err, code
end
M.post_retry = post_retry

-- ask{ cfg, system, history, user, user_name, context, conv_id, tools, run_tool } -> text | nil, err, code
function M.ask(o)
  local cfg = o.cfg
  local P = providers[cfg.provider] or providers.openai
  local conv = P.new(o.system, o.history or {}, cfg)
  P.add_user(conv, o.user, o.user_name, o.context)
  local tools = cfg.use_tools and M.tools_supported ~= false and o.tools or nil
  for round = 1, (cfg.tool_rounds or 4) + 1 do
    -- в последнем круге инструменты не даём: модель должна ответить текстом
    local use_tools = tools and round <= (cfg.tool_rounds or 4) and tools or nil
    local body, headers = prepare(cfg, conv, use_tools, P, o.conv_id)
    local data, err, code = post_retry(cfg, cfg.endpoint, body, headers)
    if not data and use_tools and round == 1 and (code == 400 or code == 422) then
      -- мягкая деградация: локальный сервер/модель не умеет tools -> чат без действий
      util.log("W", "tools rejected (%s), retry without tools", tostring(err))
      M.tools_supported = false
      tools = nil
      body, headers = prepare(cfg, conv, nil, P, o.conv_id)
      data, err, code = post_retry(cfg, cfg.endpoint, body, headers)
    end
    if not data then return nil, err, code end
    local res, perr = P.parse(data, conv)
    if not res then return nil, perr end
    if #res.calls == 0 then
      local text = res.text
      if cfg.max_answer_bytes and #text > cfg.max_answer_bytes then
        text = require("tmai.u8").truncate(text, cfg.max_answer_bytes)
      end
      return text
    end
    local results = {}
    for _, call in ipairs(res.calls) do
      local content, is_error
      if type(call.args) ~= "table" then
        content, is_error = "Ошибка: аргументы не являются JSON-объектом", true
      else
        local ok, out = pcall(o.run_tool, call.name, call.args)
        if ok then content = type(out) == "string" and out or json.encode(out)
        else content, is_error = "Ошибка инструмента: " .. tostring(out), true end
      end
      util.log("D", "tool %s -> %s", tostring(call.name), content:sub(1, 200))
      results[#results + 1] = { id = call.id, content = content, is_error = is_error }
    end
    P.add_tool_results(conv, results)
  end
  return nil, "слишком много вызовов инструментов"
end

-- Простой запрос без инструментов (сводка истории, реакция на записку).
function M.simple(cfg, system, user, context)
  return M.ask({ cfg = setmetatable({ use_tools = false }, { __index = cfg }), system = system, user = user, context = context })
end

return M
