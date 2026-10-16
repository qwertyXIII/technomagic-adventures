// TechnoMagic Adventures — первая загрузка мира (один раз, флаги в persistentData сервера):
//  1) правила «лёгкого выживания» (дальше хост может менять их сам через /gamerule);
//  2) разбитая спасательная капсула на точке появления: шаблон kubejs/data/tm/structure/crash_capsule.nbt
//     (генерируется tools/gen/gen_capsule.py), случайный поворот, «якорь» — центр пола внутри капсулы;
//     подсыпка грунта под воронку; точка возрождения — внутри капсулы;
//  3) счётчики: tm_story (сюжет, для диалогов NPC), tm_ai_repair (ремонт ядра ЛОЦМАНа).
// Стартовый набор лежит в шкафчике Lootr внутри капсулы (loot table tm:chests/capsule_locker) — у каждого свой.

const CAPSULE = {
  id: 'tm:crash_capsule',
  size: [23, 14, 23],
  anchor: [11, 3, 11],   // центр пола внутри капсулы (координаты шаблона)
  ground: 5,             // уровень исходной поверхности в шаблоне
  core: [11, 2, 15],     // ядро ЛОЦМАНа (координаты шаблона)
  coreCharge: 30000      // FE: остаточный заряд при старте мира
}

// Поворот как в StructureTemplate (вокруг угла шаблона)
function tmRotXZ(rot, x, z) {
  if (rot === 'clockwise_90') return [-z, x]
  if (rot === '180') return [-x, -z]
  if (rot === 'counterclockwise_90') return [z, -x]
  return [x, z]
}

function tmApplyRules(server) {
  const rules = [
    'keepInventory true',             // модов на могилы нет; смерть в космосе/Пустоте не должна стирать прогресс
    'playersSleepingPercentage 34',   // хватит одного спящего из трёх
    'doInsomnia false',               // без фантомов
    'spawnRadius 0',                  // все появляются внутри капсулы
    // Born in Chaos: выключаем самых «нечестных» (у мода нет файла конфига — только правила)
    'theappearanceoftheNightmareStalker false',
    'lifestealerSpawn false',
    'krampusSpawn false',
    'naughtinessMechanics false',
    'skeletonBombSpawn false',
    'phantomCreeperSpawn false',
    'fallenChaosKnightSpawn false'
  ]
  rules.forEach(r => server.runCommandSilent('gamerule ' + r))
}

function tmPlaceCapsule(server) {
  const level = server.overworld()
  const spawn = level.sharedSpawnPos
  const sx = spawn.x, sz = spawn.z
  // поверхность: первый сверху твёрдый блок, не листва, не бревно, не заменяемое (трава, снег)
  let sy = spawn.y
  // Rhino: одинаковые имена const/let в разных циклах одной функции дают «redeclaration» — имена уникальные
  for (let ys = Math.min(spawn.y + 40, 300); ys > spawn.y - 40; ys--) {
    let top = level.getBlock(sx, ys, sz)
    if (!top.blockState.isAir() && !top.id.includes('leaves') && !top.hasTag('minecraft:logs') && !top.hasTag('minecraft:replaceable')) { sy = ys + 1; break }
  }
  const rots = ['none', 'clockwise_90', '180', 'counterclockwise_90']
  const rot = rots[Math.floor(Math.random() * 4)]
  const a = tmRotXZ(rot, CAPSULE.anchor[0], CAPSULE.anchor[2])
  const ox = sx - a[0], oz = sz - a[1], oy = sy - CAPSULE.ground
  const res = server.runCommandSilent(`execute in minecraft:overworld run place template ${CAPSULE.id} ${ox} ${oy} ${oz} ${rot}`)
  console.info(`[TM] capsule at ${ox} ${oy} ${oz} rot=${rot} result=${res}`)

  // подсыпка: под каждой колонной воронки заполнить пустоту грунтом (до 12 блоков вниз)
  const R = 10, cx = CAPSULE.anchor[0], cz = CAPSULE.anchor[2]
  for (let lx = 0; lx < CAPSULE.size[0]; lx++) {
    for (let lz = 0; lz < CAPSULE.size[2]; lz++) {
      let d = Math.hypot(lx - cx, lz - cz)
      if (d > R) continue
      let depth = Math.round(3 * (1 - (d / R) * (d / R)))
      let r = tmRotXZ(rot, lx, lz)
      let wx = ox + r[0], wz = oz + r[1]
      for (let yf = oy + CAPSULE.ground - depth - 2, n = 0; n < 12; yf--, n++) {
        let fill = level.getBlock(wx, yf, wz)
        if (!fill.blockState.isAir() && !fill.blockState.liquid()) break
        fill.set('minecraft:dirt')
      }
    }
  }
  // остаточный заряд ядра ЛОЦМАНа: несколько минут работы до того, как экипаж разожжёт генератор
  try {
    let c = tmRotXZ(rot, CAPSULE.core[0], CAPSULE.core[2])
    let core = level.getBlock(ox + c[0], oy + CAPSULE.core[1], oz + c[1])
    if (core.id === 'kubejs:ai_core' && core.entity) {
      core.entity.attachments.get('energy').setEnergyStored(CAPSULE.coreCharge)
      core.entity.setChanged()
    }
  } catch (err) {
    console.warn('[TM] core charge: ' + err)
  }
  const p = tmRotXZ(rot, CAPSULE.anchor[0], CAPSULE.anchor[2])
  const spawnY = oy + CAPSULE.anchor[1]
  server.runCommandSilent(`setworldspawn ${ox + p[0]} ${spawnY} ${oz + p[1]}`)
  server.persistentData.putString('tm_capsule_pos', `${ox + p[0]} ${spawnY} ${oz + p[1]}`)
}

ServerEvents.loaded(event => {
  const server = event.server
  const pd = server.persistentData
  ;['tm_story', 'tm_ai_repair'].forEach(o => server.runCommandSilent(`scoreboard objectives add ${o} dummy`))
  if (!pd.getBoolean('tm_rules_v1')) {
    tmApplyRules(server)
    server.runCommandSilent(`scoreboard players set #tm tm_ai_repair 0`)
    pd.putBoolean('tm_rules_v1', true)
    console.info('[TM] game rules applied')
  }
  if (!pd.getBoolean('tm_capsule_placed')) {
    tmPlaceCapsule(server)
    pd.putBoolean('tm_capsule_placed', true)
  }
})
