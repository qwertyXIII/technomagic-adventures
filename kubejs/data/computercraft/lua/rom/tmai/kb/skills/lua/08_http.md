HTTP
- local res, err, failRes = http.get(url[, headers][, binary]) — блокирует до ответа (уступая управление). При ошибке res = nil, err — текст, failRes — ответ с кодом (для 4xx/5xx).
- http.post(url, body[, headers][, binary]); универсально: http.get{ url = …, headers = {…}, binary = true, method = "PUT", timeout = 30 } и http.post{ url = …, body = … }.
- Ответ: res.getResponseCode(), res.getResponseHeaders(), res.readAll(), res.readLine(), res.close() — закрывать обязательно.
- Асинхронно: http.request(url[, body][, headers][, binary]) → события http_success(url, res) / http_failure(url, err, res).
- http.checkURL(url) → true или false, причина.
- Ограничения сборки: локальная сеть и localhost запрещены («Domain not permitted»), кроме сервера ИИ (только для ЛОЦМАНа). Интернет разрешён. До 16 запросов одновременно, таймаут не больше 60 с.
- Ключи API не вписывай в код: settings.get("myprog.key") — игрок вводит set myprog.key … сам.

```lua
local function getJSON(url)
  local res, err, fail = http.get(url, { ["Accept"] = "application/json" })
  if not res then
    local code = fail and fail.getResponseCode() or "?"
    if fail then fail.close() end
    return nil, "HTTP " .. tostring(code) .. ": " .. tostring(err)
  end
  local body = res.readAll(); res.close()
  local data = textutils.unserializeJSON(body)
  if data == nil then return nil, "bad JSON" end
  return data
end
```

WEBSOCKET
- local ws, err = http.websocket(url[, headers]); ws.send(text[, binary]); local msg = ws.receive([таймаут]); ws.close(). События websocket_message(url, msg, binary), websocket_closed(url, причина, код).

JSON И ДАННЫЕ
- textutils.serializeJSON(t) / textutils.unserializeJSON(s); пустой массив — textutils.empty_json_array, null — textutils.json_null.
- Base64 (с 1.119): local b64 = require("cc.base64"); b64.encode(s), b64.decode(s).

МОДУЛИ ROM (require)
- cc.strings: wrap(text, width) → таблица строк; ensure_width(s, w); split(s, разделитель[, plain]).
- cc.pretty: local pretty = require("cc.pretty"); pretty.print(pretty.pretty(таблица)) — красивая печать для отладки.
- cc.expect: local expect = require("cc.expect").expect; expect(1, arg, "number") — проверка аргументов.
- cc.completion — дополнение для read().
- cc.audio.dfpwm: декодер/кодер DFPWM для колонки: local dfpwm = require("cc.audio.dfpwm"); local dec = dfpwm.make_decoder(); local pcm = dec(chunk); speaker.playAudio(pcm) (при false — os.pullEvent("speaker_audio_empty") и повтор).
- cc.image.nft — картинки NFT; paintutils.loadImage/drawImage — картинки .nfp.
- Свои модули: require("mylib") ищет mylib.lua в каталоге программы (/tmai_scripts для tmexec) и /rom/modules/main. Но проще держать всё в одном файле.
