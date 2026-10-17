// TechnoMagic Adventures — переезд ЛОЦМАНа: «модуль переноса» (kubejs:ai_transfer_module; предмет описан в
// tools/gen/lore.py, рецепт — tm_recipes.js). Блоки ИИ, которые в выживании не ломаются, переносятся им:
//   * штурманский модуль — командный компьютер TM-NAV (в выживании его нельзя ни сломать, ни поставить):
//     сохраняются ID компьютера (а значит, все его файлы: спаривание с ИИ, перезарядки, выданные награды) и метка;
//     на новом месте модуль включается сам;
//   * ядро ИИ kubejs:ai_core — с зарядом; детали из его отсека возвращаются игроку.
// Сам компьютер ИИ (TM-AI, продвинутый) ломается киркой как обычно: CC: Tweaked сохраняет в предмете ID и метку,
// память ИИ (файлы /tmai) остаётся с ним. Уровень ремонта ядра хранится в мире (tm_ai_core.js) и не теряется.
//
// Управление: ПКМ пустым модулем по штурманскому модулю или ядру — упаковать; Shift+ПКМ заряженным модулем
// по блоку — поставить на эту грань. После распаковки модуль снова пуст и годится для следующего блока.
// Админ (op): /tmreloc info | pack <x y z> | unpack <x y z> — то же без модуля в руке (pack бросает заряженный
// модуль на землю, unpack берёт заряженный модуль из руки или ближайший с земли в 16 блоках); нужен и для автотестов.
//
// Защита:
//   * упаковать можно только СВОЙ штурманский модуль: его место (и ID компьютера, когда известен) записаны в
//     persistentData сервера (tm_nav_pos / tm_nav_id) при создании капсулы и при каждой распаковке; чужой или
//     поставленный админом командный компьютер модуль не возьмёт. Старые миры (капсула поставлена до этой
//     версии): командный компьютер с меткой TM-NAV возле капсулы (tm_capsule_pos) — один раз;
//   * дюп: у заряженного модуля одноразовый жетон; жетоны «в пути» лежат в persistentData (tm_reloc).
//     Упаковка: жетон в реестр, потом снять блок; распаковка: жетон гасится ДО установки блока (не вышло —
//     возвращается). Копия модуля (креатив, дюп-баг) ничего не поставит;
//   * заряженный модуль, выпавший на землю, не исчезает и не горит/не ломается (иначе блок ИИ пропал бы навсегда).
// Подсказка для штурманского модуля: где стоит компьютер ИИ (command storage tm:ai ai_pos) — чтобы радио
// (беспроводной модем) можно было ставить и на компьютер ИИ (rom/programs/tmnav.lua, status).
//
// Rhino (KubeJS 2101): let/const ВНУТРИ вложенных блоков (if/else/try/циклы) дают «redeclaration of var» при
// повторных вызовах (проверено на тест-сервере). Поэтому все переменные объявлены в начале функций, имена уникальны.

const TM_RELOC = {
  module: 'kubejs:ai_transfer_module',
  nav: 'computercraft:computer_command',
  core: 'kubejs:ai_core',
  navLabel: 'TM-NAV',
  aiLabel: 'TM-AI',
  legacyRadius: 12,   // старый мир: штурманский модуль ищется в этом радиусе от точки капсулы
  names: { nav: 'штурманский модуль', core: 'ядро ИИ' },
  done: {
    nav: 'Штурманский модуль на месте и включён. Свяжите его с компьютером ИИ: проводные модемы и кабель ' +
      '(или беспроводной/эндер-модем на обоих). Радио ЛОЦМАНа — беспроводной модем на модуле или на компьютере ИИ.',
    core: 'Ядро на месте. Поставьте его вплотную к компьютеру ИИ (лучше под ним) и подведите энергию.'
  }
}
const tmRelocActed = {}  // ник -> тик последнего действия (гасим второе событие клика — левой рукой)

function tmRelocWhere(wBlock) {
  return `${wBlock.dimension} ${wBlock.x} ${wBlock.y} ${wBlock.z}`
}

// Данные заряженного модуля (CompoundTag) или null для пустого
function tmRelocPacked(pStack) {
  const pData = pStack.customData
  if (!pData || !pData.contains('tm_reloc')) return null
  return pData.getCompound('tm_reloc')
}

function tmRelocLedger(lServer) {
  return lServer.persistentData.getCompound('tm_reloc')   // жетоны «в пути»: token -> kind
}

// ---------- признак «свой штурманский модуль» ----------
function tmRelocIsOurNav(oServer, oBlock, oNbt) {
  const oPd = oServer.persistentData
  const oId = oNbt.contains('ComputerId') ? Number(oNbt.getInt('ComputerId')) : -1
  const oKnown = oPd.contains('tm_nav_id') ? Number(oPd.getInt('tm_nav_id')) : -1
  const oCap = String(oPd.getString('tm_capsule_pos')).split(' ')
  let oDist2 = 1e9
  if (String(oNbt.getString('Label')) !== TM_RELOC.navLabel) return false
  if (oPd.getBoolean('tm_nav_known')) {
    return String(oPd.getString('tm_nav_pos')) === tmRelocWhere(oBlock) && (oKnown < 0 || oKnown === oId)
  }
  // старый мир: реестра ещё нет — модуль капсулы стоит в паре блоков от её центра
  if (oCap.length !== 3 || String(oBlock.dimension) !== 'minecraft:overworld') return false
  oDist2 = Math.pow(oBlock.x - Number(oCap[0]), 2) + Math.pow(oBlock.y - Number(oCap[1]), 2) + Math.pow(oBlock.z - Number(oCap[2]), 2)
  return oDist2 <= TM_RELOC.legacyRadius * TM_RELOC.legacyRadius
}

// ---------- упаковка: блок -> заряженный модуль ----------
// give(stack) — куда вернуть детали из отсека ядра. Возвращает { stack, title } или { error }.
function tmRelocPackBlock(kLevel, kBlock, kGive) {
  const kServer = kLevel.server
  const kKind = kBlock.id === TM_RELOC.nav ? 'nav' : (kBlock.id === TM_RELOC.core ? 'core' : null)
  const kData = NBT.compoundTag()
  const kWhere = tmRelocWhere(kBlock)
  const kToken = Date.now().toString(36) + '-' + Math.floor(Math.random() * 2147483647).toString(36)
  let kNbt = null, kId = -1, kEntity = null, kEnergy = 0, kInv = null, kSlot = 0, kTitle = '', kLedger = null, kPacked = null, kCustom = null
  if (!kKind) return { error: 'Модуль переноса берёт только штурманский модуль ЛОЦМАНа и ядро ИИ.' }
  if (kKind === 'nav') {
    kNbt = kBlock.entityData
    if (!kNbt || !tmRelocIsOurNav(kServer, kBlock, kNbt)) {
      return { error: 'Это не штурманский модуль ЛОЦМАНа. Модуль переноса берёт только его и ядро ИИ.' }
    }
    kId = kNbt.contains('ComputerId') ? Number(kNbt.getInt('ComputerId')) : -1
    kData.putInt('id', kId)
    kTitle = kId >= 0 ? `штурманский модуль (компьютер #${kId})` : 'штурманский модуль'
  } else {
    kEntity = kBlock.entity
    if (!kEntity) return { error: 'Ядро недоступно.' }
    kEnergy = Number(kEntity.attachments.get('energy').getEnergyStored())
    kInv = kEntity.attachments.get('cargo')
    for (kSlot = 0; kSlot < kInv.slots; kSlot++) {   // детали «на вырост» из отсека ядра — игроку
      if (!kInv.getStackInSlot(kSlot).isEmpty()) {
        kGive(kInv.getStackInSlot(kSlot).copy())
        kInv.setStackInSlot(kSlot, Item.empty)
      }
    }
    kData.putInt('energy', kEnergy)
    kTitle = `ядро ИИ (${kEnergy} FE)`
  }
  kData.putString('kind', kKind)
  kData.putString('token', kToken)
  kData.putString('from', kWhere)

  // порядок против потерь и дюпа: жетон в реестр -> снять блок (не вышло — жетон назад) -> заряженный модуль
  kLedger = tmRelocLedger(kServer)
  kLedger.putString(kToken, kKind)
  kServer.persistentData.put('tm_reloc', kLedger)
  kBlock.set('minecraft:air')
  if (kLevel.getBlock(kBlock.x, kBlock.y, kBlock.z).id !== 'minecraft:air') {   // LevelBlock кэширует — читаем заново
    kLedger.remove(kToken)
    kServer.persistentData.put('tm_reloc', kLedger)
    return { error: 'Не удалось снять блок.' }
  }
  if (kKind === 'nav') {
    kServer.persistentData.putBoolean('tm_nav_known', true)
    kServer.persistentData.putString('tm_nav_pos', '')
    if (kId >= 0) kServer.persistentData.putInt('tm_nav_id', kId)
  }

  kPacked = Item.of(TM_RELOC.module)
  kCustom = NBT.compoundTag()
  kCustom.put('tm_reloc', kData)
  kPacked.setCustomData(kCustom)
  kPacked.setCustomName(Text.aqua('Модуль переноса: ' + TM_RELOC.names[kKind]).italic(false))
  kPacked.setLore([
    Text.gray('Внутри: ' + kTitle).italic(false),
    Text.yellow('Shift+ПКМ по блоку — поставить на эту грань').italic(false)
  ])
  kPacked.setGlintOverride(true)
  console.info(`[TM] relocate: packed ${kKind} ${kTitle} from ${kWhere} token=${kToken}`)
  return { stack: kPacked, title: kTitle }
}

// ---------- распаковка: заряженный модуль -> блок на клетке target ----------
// facing — куда «смотрит» штурманский модуль (north/south/west/east). Возвращает { kind } или { error, spent }.
function tmRelocUnpackTo(uLevel, uTarget, uData, uFacing) {
  const uServer = uLevel.server
  const uKind = String(uData.getString('kind')), uToken = String(uData.getString('token'))
  const uLedger = tmRelocLedger(uServer)
  const uWhere = tmRelocWhere(uTarget)
  const uId = uData.contains('id') ? Number(uData.getInt('id')) : -1
  const uTag = NBT.compoundTag()   // данные штурманского модуля: ID компьютера (его файлы), метка, «включён»
  let uBlocked = false, uPlaced = null, uLoaded = null
  if (!uLedger.contains(uToken) || String(uLedger.getString(uToken)) !== uKind) {
    return { error: 'Этот заряд уже распакован в другом месте — копия недействительна. Модуль очищен.', spent: true }
  }
  if (!uTarget.blockState.canBeReplaced() || uLevel.isOutsideBuildHeight(uTarget.pos)) {
    return { error: 'Здесь не поставить: нужна свободная клетка рядом с гранью, по которой вы кликнули.' }
  }
  uTarget.getPlayersInRadius(3).forEach(pl => {
    if (pl.boundingBox.intersects(uTarget.x, uTarget.y, uTarget.z, uTarget.x + 1, uTarget.y + 1, uTarget.z + 1)) uBlocked = true
  })
  if (uBlocked) return { error: 'Клетка занята игроком.' }

  // жетон гасим ДО установки (копия модуля уже ничего не поставит); не вышло поставить — возвращаем жетон.
  // Ставим через API, не командой: внутри другой команды (/tmreloc) ванильные команды откладываются до её конца.
  uLedger.remove(uToken)
  uServer.persistentData.put('tm_reloc', uLedger)
  if (uKind === 'nav') uTarget.set(TM_RELOC.nav, { facing: uFacing, state: 'off' })
  else uTarget.set(TM_RELOC.core)
  uPlaced = uLevel.getBlock(uTarget.x, uTarget.y, uTarget.z)   // свежий объект: LevelBlock кэширует состояние
  if (uPlaced.id === TM_RELOC.nav && uPlaced.entity) {
    if (uId >= 0) uTag.putInt('ComputerId', uId)
    uTag.putString('Label', TM_RELOC.navLabel)
    uTag.putBoolean('On', true)            // включится сам на следующем тике: терминал командного компьютера игрокам недоступен
    uPlaced.setEntityData(uTag)
    uLoaded = uPlaced.entityData
  }
  if (uPlaced.id !== (uKind === 'nav' ? TM_RELOC.nav : TM_RELOC.core) || !uPlaced.entity ||
      (uKind === 'nav' && (!uLoaded || String(uLoaded.getString('Label')) !== TM_RELOC.navLabel ||
        (uId >= 0 && Number(uLoaded.getInt('ComputerId')) !== uId)))) {
    if (uPlaced.id === TM_RELOC.nav) uPlaced.set('minecraft:air')   // без своего ID модуль потерял бы память — убрать
    uLedger.putString(uToken, uKind)
    uServer.persistentData.put('tm_reloc', uLedger)
    console.error(`[TM] relocate: unpack ${uKind} at ${uWhere} failed: got ${uPlaced.id} ${uLoaded}`)
    return { error: 'Не удалось поставить блок.' }
  }
  if (uKind === 'nav') uServer.persistentData.putString('tm_nav_pos', uWhere)
  else {
    uPlaced.entity.attachments.get('energy').setEnergyStored(uData.getInt('energy'))
    uPlaced.entity.setChanged()
  }
  uServer.runCommandSilent(`execute in ${uTarget.dimension} run playsound minecraft:block.beacon.power_select block @a ${uTarget.x} ${uTarget.y} ${uTarget.z} 0.6 1.6`)
  console.info(`[TM] relocate: unpacked ${uKind} at ${uWhere} facing=${uFacing} token=${uToken}`)
  return { kind: uKind }
}

// Вызов с перехватом ошибок: сбой скрипта не должен оставлять игрока без ответа (подробности — в логе сервера)
function tmRelocSafe(sWhat, sFn) {
  try {
    return sFn()
  } catch (sErr) {
    console.error(`[TM] relocate: ${sWhat} failed: ${sErr}`)
    return { error: 'Сбой модуля переноса. Подробности — в логе сервера (у хозяина мира).' }
  }
}

// ---------- игрок с модулем в руке ----------
function tmRelocSay(tPlayer, tText) {
  tPlayer.tell(Text.aqua('[Модуль переноса] ').append(Text.white(tText)))
}

// Куда повернуть штурманский модуль — лицом к игроку. Vanilla getDirection() из Rhino не видна («Cannot find
// function getDirection» на ServerPlayer) — берём свойство KubeJS facing; не вышло — north (это только внешний вид).
function tmRelocFacing(fEntity) {
  let fDir = 'north'
  try {
    fDir = String(fEntity.facing.getOpposite().getSerializedName())
  } catch (fErr) {
    console.warn(`[TM] relocate: facing unavailable: ${fErr}`)
  }
  return fDir
}

// Shift+ПКМ заряженным модулем: поставить блок на кликнутую грань
function tmRelocClickUnpack(event, cPlayer, cData) {
  const cClicked = event.block
  const cTarget = cClicked.blockState.canBeReplaced() ? cClicked : cClicked.offset(event.facing)
  const cFacing = tmRelocFacing(cPlayer)
  const cRes = tmRelocSafe('unpack', () => tmRelocUnpackTo(event.level, cTarget, cData, cFacing))
  if (!cRes.error || cRes.spent) cPlayer.setItemInHand(event.hand, Item.of(TM_RELOC.module))
  tmRelocSay(cPlayer, cRes.error ? cRes.error : TM_RELOC.done[cRes.kind])
}

// ПКМ пустым модулем по штурманскому модулю или ядру: упаковать
function tmRelocClickPack(event, qPlayer) {
  const qRes = tmRelocSafe('pack', () => tmRelocPackBlock(event.level, event.block, st => qPlayer.give(st)))
  if (qRes.error) {
    tmRelocSay(qPlayer, qRes.error)
    return
  }
  qPlayer.setItemInHand(event.hand, qRes.stack)
  tmRelocSay(qPlayer, `Упакован ${qRes.title}. Поставить на новом месте: Shift+ПКМ по блоку.`)
}

BlockEvents.rightClicked(event => {
  const rPlayer = event.player
  const rStack = rPlayer ? rPlayer.mainHandItem : null
  const rName = rPlayer ? String(rPlayer.username) : ''
  const rTick = Number(event.level.server.tickCount)
  const rId = event.block.id
  const rIsAi = rId === TM_RELOC.nav || rId === TM_RELOC.core
  const rData = rStack && rStack.id === TM_RELOC.module ? tmRelocPacked(rStack) : null
  if (!rPlayer || rPlayer.isFake() || rStack.id !== TM_RELOC.module) return
  if (String(event.hand) !== 'MAIN_HAND') {
    if (tmRelocActed[rName] === rTick) event.cancel()   // клик уже обработан основной рукой
    return
  }
  if (rData && !rPlayer.isShiftKeyDown()) {
    if (rIsAi) tmRelocSay(rPlayer, 'Модуль уже заряжен. Поставить: Shift+ПКМ по блоку.')
    return                                            // обычный ПКМ (сундук, дверь…) работает как всегда
  }
  if (rData) {
    tmRelocActed[rName] = rTick
    tmRelocClickUnpack(event, rPlayer, rData)
    event.cancel()
  }
  if (rIsAi) {
    tmRelocActed[rName] = rTick
    tmRelocClickPack(event, rPlayer)
    event.cancel()
  }
  if (rPlayer.isShiftKeyDown() && (rId === 'computercraft:computer_advanced' || rId === 'computercraft:computer_normal')) {
    tmRelocSay(rPlayer, 'Обычному компьютеру модуль не нужен: сломайте его киркой — метка и память сохранятся в предмете.')
    event.cancel()
  }
})

// Заряженный модуль на земле не исчезает и не ломается: иначе штурманский модуль или ядро пропали бы навсегда.
EntityEvents.spawned('minecraft:item', event => {
  const eItem = event.entity.item
  if (eItem && eItem.id === TM_RELOC.module && tmRelocPacked(eItem)) {
    event.entity.setUnlimitedLifetime()
    event.entity.setInvulnerable(true)
  }
})

// Компьютер ИИ поставлен (после переезда) — подсказка штурманскому модулю, где искать радио на нём.
// Метка приходит из предмета; читаем на следующем тике, когда данные блока точно применены.
function tmRelocAiPlaced(event) {
  const aBlock = event.block, aServer = event.level.server
  aServer.scheduleInTicks(1, () => {
    const aNbt = aBlock.entityData
    if (aNbt && String(aNbt.getString('Label')) === TM_RELOC.aiLabel) {
      aServer.runCommandSilent(`data modify storage tm:ai ai_pos set value "${tmRelocWhere(aBlock)}"`)
    }
  })
}
BlockEvents.placed('computercraft:computer_advanced', tmRelocAiPlaced)
BlockEvents.placed('computercraft:computer_normal', tmRelocAiPlaced)

// Админ переставил штурманский модуль вручную (креатив) — обновить реестр, чтобы модуль переноса его узнал.
BlockEvents.placed(TM_RELOC.nav, event => {
  const nBlock = event.block, nServer = event.level.server
  nServer.scheduleInTicks(1, () => {
    const nNbt = nBlock.entityData
    const nPd = nServer.persistentData
    if (!nNbt || String(nNbt.getString('Label')) !== TM_RELOC.navLabel || !nNbt.contains('ComputerId')) return
    if (nPd.contains('tm_nav_id') && Number(nPd.getInt('tm_nav_id')) === Number(nNbt.getInt('ComputerId'))) {
      nPd.putString('tm_nav_pos', tmRelocWhere(nBlock))
      nPd.putBoolean('tm_nav_known', true)
    }
  })
})

// ---------- админ-команда /tmreloc (op, уровень 2) ----------
function tmRelocReply(ctx, text) {
  ctx.source.sendSystemMessage(Text.of('[tmreloc] ' + text))
  console.info('[TM] tmreloc: ' + text)
  return 1
}

function tmRelocCmdInfo(ctx) {
  const iPd = ctx.source.server.persistentData
  return tmRelocReply(ctx, `nav_pos="${iPd.getString('tm_nav_pos')}" nav_id=${iPd.contains('tm_nav_id') ? iPd.getInt('tm_nav_id') : 'none'} ` +
    `known=${iPd.getBoolean('tm_nav_known')} in_transit=${tmRelocLedger(ctx.source.server).size()}`)
}

function tmRelocCmdPack(ctx, xBlock) {
  const xRes = tmRelocSafe('pack', () => tmRelocPackBlock(ctx.source.level, xBlock, st => xBlock.popItem(st)))
  if (xRes.error) return tmRelocReply(ctx, 'error: ' + xRes.error)
  xBlock.popItem(xRes.stack)                       // заряженный модуль — на землю (игрок поднимет)
  return tmRelocReply(ctx, 'packed ' + xRes.title)
}

function tmRelocCmdUnpack(ctx, yTarget) {
  const yPlayer = ctx.source.player
  const yBox = AABB.of(yTarget.x - 16, yTarget.y - 16, yTarget.z - 16, yTarget.x + 17, yTarget.y + 17, yTarget.z + 17)
  const yFacing = ctx.source.entity ? tmRelocFacing(ctx.source.entity) : 'north'   // execute as <сущность> — как у игрока
  let yHolder = null, yStack = null, yBest = 1e9, yRes = null
  if (yPlayer && tmRelocPacked(yPlayer.mainHandItem)) yStack = yPlayer.mainHandItem
  else {   // ближайший заряженный модуль на земле
    ctx.source.level.getEntitiesWithin(yBox).forEach(en => {
      const yDist = en.distanceToSqr(yTarget.x + 0.5, yTarget.y + 0.5, yTarget.z + 0.5)
      if (en.type !== 'minecraft:item' || en.item.id !== TM_RELOC.module || !tmRelocPacked(en.item) || yDist >= yBest) return
      yBest = yDist; yHolder = en; yStack = en.item
    })
  }
  if (!yStack) return tmRelocReply(ctx, 'error: no packed module (main hand or on the ground within 16 blocks)')
  yRes = tmRelocSafe('unpack', () => tmRelocUnpackTo(ctx.source.level, yTarget, tmRelocPacked(yStack), yFacing))
  if (yRes.error && !yRes.spent) return tmRelocReply(ctx, 'error: ' + yRes.error)
  if (yHolder) yHolder.discard()
  else yPlayer.setMainHandItem(Item.of(TM_RELOC.module))
  return tmRelocReply(ctx, yRes.error ? 'error: ' + yRes.error : 'unpacked ' + yRes.kind)
}

ServerEvents.commandRegistry(event => {
  const Commands = event.commands, Arguments = event.arguments
  const blockAt = ctx => {
    const bPos = Arguments.BLOCK_POS.getResult(ctx, 'pos')
    return ctx.source.level.getBlock(bPos.x, bPos.y, bPos.z)
  }
  event.register(Commands.literal('tmreloc')
    .requires(src => src.hasPermission(2))
    .then(Commands.literal('info').executes(ctx => tmRelocCmdInfo(ctx)))
    .then(Commands.literal('pack').then(Commands.argument('pos', Arguments.BLOCK_POS.create(event))
      .executes(ctx => tmRelocCmdPack(ctx, blockAt(ctx)))))
    .then(Commands.literal('unpack').then(Commands.argument('pos', Arguments.BLOCK_POS.create(event))
      .executes(ctx => tmRelocCmdUnpack(ctx, blockAt(ctx)))))
  )
})
