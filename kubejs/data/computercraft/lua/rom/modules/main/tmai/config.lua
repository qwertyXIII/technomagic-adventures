-- tmai.config — все настройки программы ЛОЦМАНа в одном месте (CC settings API).
-- Меняются на терминале компьютера капсулы (метка TM-AI): вкладка «Настройки» (стрелки, Enter),
-- или по-старому из оболочки: set tmai.api_key <ключ шлюза>. Список с группами — M.list() (для вкладки).
-- КЛЮЧИ ВВОДЯТСЯ ТОЛЬКО В ИГРЕ и хранятся в файле /.settings этого компьютера (в сохранении мира).
-- В сборке (публичный репозиторий) ключей нет и быть не должно.

local M = {}

local DEFS = {
  { group = "Нейросеть (чат)" },
  { "provider", "openai", "string", "openai (любой OpenAI-совместимый сервер) | anthropic (Messages API)" },
  { "base_url", "http://192.168.0.113:4111/v1", "string", "Адрес API чата до /chat/completions (шлюз заказчика в LAN; разрешён в computercraft-server.toml)" },
  { "api_key", "", "string", "Ключ API чата (Bearer). Для локального сервера без ключа — пусто" },
  { "model", "codex/gpt-6-luna", "string", "Имя модели у провайдера" },
  { "model_effort", "low", "string", "Уровень размышлений суффиксом модели (:low|:medium|:high|:xhigh|:max); пусто = без суффикса" },
  { "context_role", "developer", "string", "Куда класть контекст хода: developer | system | user_prefix (если сервер не терпит второго system)" },
  { "use_name_field", true, "boolean", "Передавать ник игрока полем name у сообщений игроков" },
  { "conversation_header", "X-Conversation-Id", "string", "Заголовок id сессии шлюза (пусто = не слать)" },
  { "proxy", "", "string", "Прокси, если нейросеть или OpenRouter недоступны напрямую: socks5://хост:порт (или socks4, http, https; можно логин:пароль@). Пусто — напрямую. Домашняя сеть всегда напрямую. Действует на весь мир, ставит штурманский модуль" },
  { "max_answer_bytes", 2400, "number", "Жёсткая обрезка ответа, байт (шлюз игнорирует max_tokens)" },
  { "max_tokens", 700, "number", "Предел длины ответа, токенов (если провайдер учитывает)" },
  { "max_tokens_field", "max_tokens", "string", "Имя поля лимита: max_tokens | max_completion_tokens" },
  { "temperature", -1, "number", "Температура 0..1; -1 = не передавать" },
  { "timeout", 60, "number", "Таймаут HTTP-запроса, секунд (максимум CC: Tweaked — 60; дольше — повтор)" },
  { "retries", 2, "number", "Повторы при 429 (по Retry-After) и 502/503/504" },
  { "use_tools", true, "boolean", "Разрешить инструменты (function calling): склад, разведка, поручения, программы" },
  { "tool_rounds", 0, "number", "Максимум кругов вызова инструментов на один вопрос; 0 = без ограничения (по умолчанию)" },
  { "extra_headers", "", "string", "Доп. заголовки JSON-объектом, напр. {\"HTTP-Referer\":\"tm\"}" },
  { "extra_body", "", "string", "Доп. поля тела запроса JSON-объектом" },
  { group = "Поиск по смыслу (эмбеддинги)" },
  { "emb_base_url", "https://openrouter.ai/api/v1", "string", "Адрес API эмбеддингов до /embeddings" },
  { "emb_model", "openai/text-embedding-3-small", "string", "Модель эмбеддингов" },
  { "emb_key", "", "string", "Ключ OpenRouter для эмбеддингов (пусто = поиск только по ключевым словам)" },
  { "emb_dims", 0, "number", "Размерность векторов (параметр dimensions): 0 — родная у модели (лучше качество; у text-embedding-3-small — 1536), меньше — экономит диск и время поиска" },
  { group = "Озвучка" },
  { "tts", false, "boolean", "Озвучивать ответы через колонку капсулы (и КПК с динамиком)" },
  { "tts_base_url", "https://openrouter.ai/api/v1", "string", "Адрес API озвучки до /audio/speech" },
  { "tts_model", "fish-audio/s2.1-pro-free:free", "string", "Модель TTS" },
  { "tts_key", "", "string", "Ключ для TTS (пусто = как emb_key)" },
  { "tts_voice", "19c4bc8dbc35461f8ee013f7ad2cf030", "string", "ID голоса Fish Audio (из адреса fish.audio/m/<ID>; по умолчанию «Русский Нарратор»). Пусто — модель каждый раз берёт случайный голос" },
  { "tts_rate", 44100, "number", "Частота PCM от провайдера, Гц (если голос «бурундук» или «замедленный» — поправить)" },
  { "tts_max_chars", 0, "number", "Озвучивать не длиннее N символов; 0 — весь ответ" },
  { "tts_parallel", 3, "number", "Сколько кусков озвучки (по предложениям) запрашивать одновременно, 1..6" },
  { "tts_volume", 1.0, "number", "Громкость 0..3" },
  { group = "Разговор" },
  { "allowed_players", "*", "string", "Кто может обращаться: * или ники через запятую" },
  { "player_cooldown", 6, "number", "Пауза между вопросами одного игрока, секунд" },
  { "max_input", 400, "number", "Макс. длина вопроса, символов" },
  { "hourly_limit", 120, "number", "Макс. запросов к нейросети в час (защита кошелька)" },
  { "queue_limit", 3, "number", "Макс. вопросов в очереди" },
  { group = "Контекст и память" },
  { "history_chars", 20000, "number", "Бюджет истории диалога, байт" },
  { "summary_chars", 8000, "number", "Размер сжатой сводки старого разговора, байт (сводку пишет сама нейросеть)" },
  { "kb_chars", 6000, "number", "Бюджет справки из базы знаний на один вопрос, байт" },
  { "memory_chars", 7000, "number", "Бюджет восстановленной памяти (слои) в системном промпте, байт" },
  { group = "Питание" },
  { "power_min", 2000, "number", "Минимальный заряд ядра ИИ (FE) для работы нейросети" },
  { "power_side", "bottom", "string", "Сторона компьютера, где стоит ядро (редстоун-нагрузка)" },
  { "power_think_level", 15, "number", "Сила редстоун-сигнала (0..15) к ядру, пока ИИ «думает»" },
  { group = "МЭ-сеть" },
  { "craft_confirm_over", 64, "number", "Заказ автокрафта больше N штук требует подтверждения «да КОД»" },
  { "craft_confirm_items", "", "string", "ID предметов, которые всегда требуют подтверждения, через запятую" },
  { group = "Рубка и устройства" },
  { "memory_box", "", "string", "Имя инвентаря «Ящик памяти» в сети (пусто = сундук вплотную к терминалу); выбирается во вкладке «Устройства»" },
  { "monitor", "", "string", "Имя монитора (пусто = самый большой подключённый)" },
  { "pin", "", "string", "ПИН вкладки «Настройки», 4–8 цифр (пусто — без ПИН). С ПИН-кодом Ctrl+T не останавливает ЛОЦМАНа. Забыли — хозяин мира удаляет строку tmai.pin в saves/<мир>/computercraft/computer/<номер>/.settings" },
  { "monitor_scale", 0.5, "number", "Масштаб текста монитора: 0.5 (мелко, больше текста) .. 2" },
  { "hum", true, "boolean", "Иногда напевать ночью (колонка капсулы)" },
  { "print_records", true, "boolean", "Печатать восстановленные записи на принтере (если подключён)" },
  { "debug", false, "boolean", "Подробный лог в /tmai/log.txt" },
}

local PREFIX = "tmai."

-- Секреты: на экране показываются звёздочками.
local SECRET = { api_key = true, emb_key = true, tts_key = true, pin = true }

function M.define()
  for _, d in ipairs(DEFS) do
    if d[1] then settings.define(PREFIX .. d[1], { default = d[2], type = d[3], description = d[4] }) end
  end
end

-- Для вкладки «Настройки»: { {group=}, {key=, value=, default=, type=, desc=, secret=}, ... }
function M.list()
  local out = {}
  for _, d in ipairs(DEFS) do
    if d.group then out[#out + 1] = { group = d.group }
    else
      out[#out + 1] = { key = d[1], value = settings.get(PREFIX .. d[1]), default = d[2], type = d[3], desc = d[4],
        secret = SECRET[d[1]] or false }
    end
  end
  return out
end

-- Сохранить значение из строки (вкладка «Настройки»). Возвращает true или nil, ошибка.
-- Адрес прокси: socks5|socks4|http|https://[логин:пароль@]хост:порт или "". true или nil, ошибка.
local PROXY_SCHEMES = { socks5 = true, socks4 = true, http = true, https = true }
function M.check_proxy(url)
  if url == "" then return true end
  local scheme, rest = url:match("^(%a%w*)://([^%s/]+)/?$")
  if not scheme or not PROXY_SCHEMES[scheme:lower()] then return nil, "формат: socks5://хост:порт (или socks4, http, https)" end
  local host, port = (rest:gsub("^.*@", "")):match("^([%w%.%-]+):(%d+)$")
  if not host or tonumber(port) < 1 or tonumber(port) > 65535 then return nil, "формат: socks5://хост:порт" end
  return true
end

-- Прокси без логина и пароля — для экранов.
function M.proxy_label(url)
  if not url or url == "" then return "нет" end
  return (url:gsub("//[^@/]*@", "//"))
end

function M.set(key, raw)
  local def
  for _, d in ipairs(DEFS) do if d[1] == key then def = d end end
  if not def then return nil, "нет такой настройки" end
  local v = raw
  if def[3] == "number" then
    v = tonumber(raw)
    if not v then return nil, "нужно число" end
  elseif def[3] == "boolean" then
    if type(raw) == "boolean" then v = raw
    elseif raw == "true" or raw == "да" or raw == "1" or raw == "вкл" then v = true
    elseif raw == "false" or raw == "нет" or raw == "0" or raw == "выкл" then v = false
    else return nil, "нужно да/нет" end
  else
    v = tostring(raw or "")
    if key == "pin" then
      v = v:match("^%s*(.-)%s*$")
      if v ~= "" and not v:match("^%d%d%d%d%d?%d?%d?%d?$") then return nil, "ПИН — 4–8 цифр (пусто — без ПИН)" end
    end
    if key == "proxy" then
      v = v:match("^%s*(.-)%s*$")
      local ok, err = M.check_proxy(v)
      if not ok then return nil, err end
    end
  end
  settings.set(PREFIX .. key, v)
  settings.save()
  return true
end

local function join_url(base, path)
  base = (base or ""):gsub("/+$", "")
  if base == "" then return "" end
  if base:sub(-#path) == path then return base end   -- уже полный адрес
  return base .. path
end

function M.get()
  local c = {}
  for _, d in ipairs(DEFS) do if d[1] then c[d[1]] = settings.get(PREFIX .. d[1]) end end
  if c.provider == "anthropic" then
    if c.base_url == "http://192.168.0.113:4111/v1" then c.base_url = "https://api.anthropic.com/v1" end
    c.endpoint = join_url(c.base_url, "/messages")
  else
    c.endpoint = join_url(c.base_url, "/chat/completions")
  end
  c.emb_endpoint = join_url(c.emb_base_url, "/embeddings")
  c.tts_endpoint = join_url(c.tts_base_url, "/audio/speech")
  c.allowed = {}
  for n in (c.allowed_players or "*"):gmatch("[^, ]+") do c.allowed[n] = true end
  if c.tts_key == "" then c.tts_key = c.emb_key end
  c.timeout = math.max(5, math.min(tonumber(c.timeout) or 60, 60))   -- CC: http.request принимает таймаут 0..60 с
  c.confirm_items = {}
  for n in (c.craft_confirm_items or ""):gmatch("[^, ]+") do c.confirm_items[n] = true end
  return c
end

-- Готова ли связь с нейросетью; иначе текст подсказки для терминала.
function M.check(c)
  if c.endpoint == "" then return false, "Нет адреса нейросети: Настройки → base_url (http://IP:порт/v1)" end
  if c.model == "" then return false, "Не задана модель: Настройки → model" end
  if not http then return false, "HTTP в CC: Tweaked выключен (computercraft-server.toml)" end
  return true
end

return M
