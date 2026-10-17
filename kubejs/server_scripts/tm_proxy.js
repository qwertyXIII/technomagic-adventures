// priority: 0
// Необязательный прокси для интернет-запросов компьютеров CC: Tweaked (ЛОЦМАН → нейросети, поиск, озвучка),
// когда сайт недоступен напрямую. Задаётся во вкладке «Настройки» ЛОЦМАНа (proxy; команду выполняет TM-NAV)
// или опом:
//   /tmproxy                                          — показать
//   /tmproxy set socks5://[логин:пароль@]хост:порт    (socks5, socks4, http, https)
//   /tmproxy off
//   /tmproxy check <хост>                             — как пойдёт запрос к хосту: через прокси, напрямую, запрещён
// Хранится в данных мира (tm_proxy) и включается при каждом запуске. Через прокси — только внешние адреса;
// домашняя сеть ($private: шлюз чата, сам прокси) — напрямую.
// Встроенный прокси CC включается признаком use_proxy у правила, а при пустом адресе прокси такое правило
// ломает все запросы, поэтому в конфиге use_proxy нет, а два своих правила ставим в начало списка на лету
// (CC читает правила и адрес прокси при каждом запросе). Почему так — ADR-0008.

const TmCoreConfig = Java.loadClass('dan200.computercraft.core.CoreConfig')
const TmProxyType = Java.loadClass('dan200.computercraft.core.apis.http.options.ProxyType')
const TmAddressRule = Java.loadClass('dan200.computercraft.core.apis.http.options.AddressRule')
const TmPartialOptions = Java.loadClass('dan200.computercraft.core.apis.http.options.PartialOptions')
const TmOptional = Java.loadClass('java.util.Optional')
const TmOptionalInt = Java.loadClass('java.util.OptionalInt')
const TmOptionalLong = Java.loadClass('java.util.OptionalLong')
const TmArrayList = Java.loadClass('java.util.ArrayList')
const TmNetworkUtils = Java.loadClass('dan200.computercraft.core.apis.http.NetworkUtils')

const TM_PROXY_RE = /^(socks5|socks4|http|https):\/\/(?:([^:@\/\s]*)(?::([^@\/\s]*))?@)?([A-Za-z0-9.\-]+):(\d{1,5})\/?$/i

let tmProxyOurs = null        // наши два правила в начале списка CC, пока прокси включён
// Наше ли это правило. equals KubeJS скрипту не даёт; `==` у обёрток Java сравнивает сами объекты, а на случай,
// если обёртки разные, — строка Object.toString (класс@хеш объекта: у AddressRule он не переопределён).
function tmProxyIsOurs(rule) {
  return tmProxyOurs != null && (rule == tmProxyOurs[0] || String(rule) === String(tmProxyOurs[0]))
}

// "socks5://user:pass@host:port" -> { type, user, pass, host, port } или null
function tmProxyParse(url) {
  let m = TM_PROXY_RE.exec(String(url || '').trim())
  if (!m) return null
  let port = parseInt(m[5], 10)
  if (!(port >= 1 && port <= 65535)) return null
  return { type: String(m[1]).toUpperCase(), user: m[2] ? decodeURIComponent(m[2]) : '', pass: m[3] ? decodeURIComponent(m[3]) : '',
    host: String(m[4]), port: port }
}

// Правило без действия (действие дадут правила конфига ниже): только «через прокси или нет».
function tmProxyRule(host, viaProxy) {
  let noLong = TmOptionalLong.empty()
  return TmAddressRule.parse(host, TmOptionalInt.empty(), new TmPartialOptions(null, noLong, noLong, TmOptionalInt.empty(), TmOptional.of(viaProxy)))
}

function tmProxyActive() {
  let rules = TmCoreConfig.httpRules
  return rules.size() > 0 && tmProxyIsOurs(rules.get(0)) && String(TmCoreConfig.httpProxyHost || '') !== ''
}

// p = результат tmProxyParse или null (выключить)
function tmProxyApply(p) {
  let cur = TmCoreConfig.httpRules
  let skip = cur.size() >= 2 && tmProxyIsOurs(cur.get(0)) ? 2 : 0   // CC мог перечитать конфиг — тогда наших там нет
  let base = new TmArrayList()
  for (let i = skip; i < cur.size(); i++) base.add(cur.get(i))
  if (!p) {
    TmCoreConfig.httpRules = base
    TmCoreConfig.httpProxyHost = ''
    tmProxyOurs = null
    return
  }
  TmCoreConfig.httpProxyType = TmProxyType.valueOf(p.type)
  TmCoreConfig.httpProxyHost = p.host
  TmCoreConfig.httpProxyPort = p.port
  TmCoreConfig.httpProxyUsername = p.user
  TmCoreConfig.httpProxyPassword = p.pass
  tmProxyOurs = [tmProxyRule('$private', false), tmProxyRule('*', true)]
  let list = new TmArrayList()
  list.add(tmProxyOurs[0])
  list.add(tmProxyOurs[1])
  for (let j = 0; j < base.size(); j++) list.add(base.get(j))
  TmCoreConfig.httpRules = list
}

function tmProxyLabel(p) {
  return p ? `${p.type} ${p.host}:${p.port}` + (p.user ? ' (с логином)' : '') : 'выключен'
}

function tmProxyReply(ctx, text, code) {
  ctx.source.sendSystemMessage(Text.of('[tmproxy] ' + text))
  console.info('[TM] proxy: ' + text)
  return code === undefined ? 1 : code
}

function tmProxyCmdShow(ctx) {
  let shown = tmProxyParse(ctx.source.server.persistentData.getString('tm_proxy'))
  return tmProxyReply(ctx, shown ? (tmProxyLabel(shown) + (tmProxyActive() ? ', работает' : ', сохранён, не включён')) : 'выключен')
}

function tmProxyCmdSet(ctx, url) {
  let sPd = ctx.source.server.persistentData
  let sParsed = null
  if (url !== '') {
    sParsed = tmProxyParse(url)
    if (!sParsed) return tmProxyReply(ctx, 'error: формат socks5://[логин:пароль@]хост:порт (или socks4, http, https)', 0)
  }
  let sErr = null
  try { tmProxyApply(sParsed) } catch (e) { sErr = e }
  if (sErr) return tmProxyReply(ctx, 'error: ' + sErr, 0)
  sPd.putString('tm_proxy', sParsed ? String(url).trim() : '')
  console.info('[TM] proxy: правил CC ' + TmCoreConfig.httpRules.size() + ', наши впереди: ' + tmProxyActive())
  return tmProxyReply(ctx, sParsed ? 'включён ' + tmProxyLabel(sParsed) : 'выключен')
}

// Как CC: Tweaked пропустит запрос к хосту — его же функциями (DNS, правила): через прокси, напрямую, запрещён.
function tmProxyCmdCheck(ctx, host) {
  let cOpts = null, cErr = null
  try {
    cOpts = TmNetworkUtils.getOptions(host, TmNetworkUtils.getAddress(host, 443, true))
  } catch (e) { cErr = String(e) }
  if (cErr) {
    let why = cErr.indexOf('not permitted') >= 0 ? 'запрещён' : (cErr.indexOf('Unknown host') >= 0 ? 'адрес не найден (DNS)' : 'не проверить (' + cErr + ')')
    return tmProxyReply(ctx, 'check ' + host + ': ' + why)
  }
  return tmProxyReply(ctx, 'check ' + host + ': ' + (cOpts.useProxy() ? 'через прокси' : 'напрямую'))
}

ServerEvents.commandRegistry(event => {
  const Commands = event.commands, Arguments = event.arguments
  event.register(Commands.literal('tmproxy')
    .requires(src => src.hasPermission(2))
    .executes(ctx => tmProxyCmdShow(ctx))
    .then(Commands.literal('off').executes(ctx => tmProxyCmdSet(ctx, '')))
    .then(Commands.literal('check').then(Commands.argument('host', Arguments.WORD.create(event))
      .executes(ctx => tmProxyCmdCheck(ctx, String(Arguments.WORD.getResult(ctx, 'host'))))))
    .then(Commands.literal('set').then(Commands.argument('url', Arguments.GREEDY_STRING.create(event))
      .executes(ctx => tmProxyCmdSet(ctx, String(Arguments.GREEDY_STRING.getResult(ctx, 'url'))))))
  )
})

// Запуск мира: включить сохранённый прокси.
ServerEvents.loaded(event => {
  let lParsed = tmProxyParse(event.server.persistentData.getString('tm_proxy'))
  if (!lParsed) return
  let lErr = null
  try { tmProxyApply(lParsed) } catch (e) { lErr = e }
  console.info('[TM] proxy: ' + (lErr ? 'error ' + lErr : 'включён ' + tmProxyLabel(lParsed) + ', правил ' + TmCoreConfig.httpRules.size()))
})

// Раз в 30 с: если CC перечитал свой конфиг (правила и адрес сброшены) — включить прокси снова.
ServerEvents.tick(event => {
  const tServer = event.server
  if (tServer.tickCount % 600 !== 0 || tmProxyOurs == null || tmProxyActive()) return
  let tParsed = tmProxyParse(tServer.persistentData.getString('tm_proxy'))
  if (!tParsed) return
  let tErr = null
  try { tmProxyApply(tParsed) } catch (e) { tErr = e }
  console.info('[TM] proxy: снова включён после перечитывания конфига CC' + (tErr ? ' — error ' + tErr : ''))
})
