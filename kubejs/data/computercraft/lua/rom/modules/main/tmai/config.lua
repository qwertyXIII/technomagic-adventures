-- tmai.config — все настройки программы ЛОЦМАНа в одном месте (CC settings API).
-- Задаются в терминале компьютера капсулы (метка TM-AI), например:
--   set tmai.api_key <ключ шлюза>
-- Остальное уже прописано по умолчанию. Список: `set`, описание: `help tmai`.
-- КЛЮЧИ ВВОДЯТСЯ ТОЛЬКО В ИГРЕ и хранятся в файле /.settings этого компьютера (в сохранении мира).
-- В сборке (публичный репозиторий) ключей нет и быть не должно.

local M = {}

local DEFS = {
  -- ── чат-модель (OpenAI-совместимый /v1/chat/completions; основной путь)
  { "provider", "openai", "string", "openai (любой OpenAI-совместимый сервер) | anthropic (Messages API)" },
  { "base_url", "http://192.168.0.113:4111/v1", "string", "Адрес API чата до /chat/completions (шлюз заказчика в LAN; разрешён в computercraft-server.toml)" },
  { "api_key", "", "string", "Ключ API чата (Bearer). Для локального сервера без ключа — пусто" },
  { "model", "codex/gpt-6-luna", "string", "Имя модели у провайдера" },
  { "model_effort", "low", "string", "Уровень размышлений суффиксом модели (:low|:medium|:high|:xhigh|:max); пусто = без суффикса" },
  { "context_role", "developer", "string", "Куда класть контекст хода: developer | system | user_prefix (если сервер не терпит второго system)" },
  { "use_name_field", true, "boolean", "Передавать ник игрока полем name у сообщений игроков" },
  { "conversation_header", "X-Conversation-Id", "string", "Заголовок id сессии шлюза (пусто = не слать)" },
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
  -- ── эмбеддинги (поиск по базе знаний по смыслу; без ключа — поиск по словам)
  { "emb_base_url", "https://openrouter.ai/api/v1", "string", "Адрес API эмбеддингов до /embeddings" },
  { "emb_model", "openai/text-embedding-3-small", "string", "Модель эмбеддингов" },
  { "emb_key", "", "string", "Ключ OpenRouter для эмбеддингов (пусто = поиск только по ключевым словам)" },
  { "emb_dims", 512, "number", "Параметр dimensions (0 = не передавать; 512 экономит диск и время)" },
  -- ── озвучка (необязательно)
  { "tts", false, "boolean", "Озвучивать ответы через колонку капсулы (и КПК с динамиком)" },
  { "tts_base_url", "https://openrouter.ai/api/v1", "string", "Адрес API озвучки до /audio/speech" },
  { "tts_model", "fish-audio/s2.1-pro-free:free", "string", "Модель TTS" },
  { "tts_key", "", "string", "Ключ для TTS (пусто = как emb_key)" },
  { "tts_voice", "", "string", "ID голоса (пусто = по умолчанию)" },
  { "tts_rate", 44100, "number", "Частота PCM от провайдера, Гц (если голос «бурундук» или «замедленный» — поправить)" },
  { "tts_max_chars", 300, "number", "Озвучивать не длиннее N символов (первый абзац)" },
  { "tts_volume", 1.0, "number", "Громкость 0..3" },
  -- ── чат
  { "triggers", "лоцман,ии,борт,ai,штурман", "string", "Слова-обращения в начале сообщения, через запятую" },
  { "chat_bytes", 900, "number", "Макс. байт в одном сообщении чата (лимит Advanced Peripherals — 1024)" },
  { "allowed_players", "*", "string", "Кто может обращаться: * или ники через запятую" },
  { "player_cooldown", 6, "number", "Пауза между вопросами одного игрока, секунд" },
  { "max_input", 400, "number", "Макс. длина вопроса, символов" },
  { "hourly_limit", 120, "number", "Макс. запросов к нейросети в час (защита кошелька)" },
  { "queue_limit", 3, "number", "Макс. вопросов в очереди" },
  -- ── контекст и память
  { "history_chars", 20000, "number", "Бюджет истории диалога, байт" },
  { "summary_chars", 8000, "number", "Размер сжатой сводки старого разговора, байт (сводку пишет сама нейросеть)" },
  { "kb_chars", 6000, "number", "Бюджет справки из базы знаний на один вопрос, байт" },
  { "memory_chars", 7000, "number", "Бюджет восстановленной памяти (слои) в системном промпте, байт" },
  -- ── энергия
  { "power_min", 2000, "number", "Минимальный заряд ядра ИИ (FE) для работы нейросети" },
  { "power_side", "bottom", "string", "Сторона компьютера, где стоит ядро (редстоун-нагрузка)" },
  { "power_think_level", 15, "number", "Сила редстоун-сигнала (0..15) к ядру, пока ИИ «думает»" },
  -- ── МЭ
  { "craft_confirm_over", 64, "number", "Заказ автокрафта больше N штук требует подтверждения «да КОД»" },
  { "craft_confirm_items", "", "string", "ID предметов, которые всегда требуют подтверждения, через запятую" },
  -- ── связь и атмосфера
  { "comm_zone", true, "boolean", "Принимать чат только от игроков в зоне связи (капсула, вышки, эндер-модем)" },
  { "hum", true, "boolean", "Иногда напевать ночью (колонка капсулы)" },
  { "print_records", true, "boolean", "Печатать восстановленные записи на принтере (если подключён)" },
  { "debug", false, "boolean", "Подробный лог в /tmai/log.txt" },
}

local PREFIX = "tmai."

function M.define()
  for _, d in ipairs(DEFS) do
    settings.define(PREFIX .. d[1], { default = d[2], type = d[3], description = d[4] })
  end
end

local function join_url(base, path)
  base = (base or ""):gsub("/+$", "")
  if base == "" then return "" end
  if base:sub(-#path) == path then return base end   -- уже полный адрес
  return base .. path
end

function M.get()
  local c = {}
  for _, d in ipairs(DEFS) do c[d[1]] = settings.get(PREFIX .. d[1]) end
  if c.provider == "anthropic" then
    if c.base_url == "http://192.168.0.113:4111/v1" then c.base_url = "https://api.anthropic.com/v1" end
    c.endpoint = join_url(c.base_url, "/messages")
  else
    c.endpoint = join_url(c.base_url, "/chat/completions")
  end
  c.emb_endpoint = join_url(c.emb_base_url, "/embeddings")
  c.tts_endpoint = join_url(c.tts_base_url, "/audio/speech")
  c.trigger_list = {}
  for raw in (c.triggers or ""):gmatch("[^,]+") do
    local t = raw:gsub("^ +", ""):gsub(" +$", "")
    if #t > 0 then c.trigger_list[#c.trigger_list + 1] = t end
  end
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
  if c.endpoint == "" then return false, "No chat address: set tmai.base_url http://IP:port/v1" end
  if c.model == "" then return false, "No model: set tmai.model <name>" end
  if not http then return false, "HTTP API disabled in computercraft-server.toml" end
  return true
end

return M
