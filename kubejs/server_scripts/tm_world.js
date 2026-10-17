// TechnoMagic Adventures — первая загрузка мира (один раз, флаги в persistentData сервера):
//  1) правила «лёгкого выживания» (дальше хост может менять их сам через /gamerule);
//  2) разбитый спасательный челнок (капсула СК-4) рядом с точкой мира: шаблон kubejs/data/tm/structure/crash_capsule.nbt
//     (генерируется tools/gen/gen_capsule.py вместе с блоком констант ниже); место — самая ровная площадка
//     в радиусе ~450 блоков (по шуму генератора, без генерации чанков), поворот — лучший для рельефа;
//     подсыпка грунта под отпечатком, точка возрождения — в жилом отсеке;
//  3) счётчики: tm_story (сюжет, для диалогов NPC), tm_ai_repair (ремонт ядра ЛОЦМАНа);
//  4) реестр для переезда ЛОЦМАНа: место штурманского модуля (tm_nav_pos) и компьютера ИИ (storage tm:ai ai_pos).
// Стартовый набор лежит в шкафчике Lootr внутри капсулы (loot table tm:chests/capsule_locker) — у каждого свой.

// <gen:capsule> — сгенерировано tools/gen/gen_capsule.py, руками не править
const CAPSULE = {
  id: 'tm:crash_capsule',
  size: [27, 17, 61],
  anchor: [13, 6, 40],   // жилой отсек: точка возрождения (координаты шаблона)
  ground: 6,             // первый воздух над исходной поверхностью в шаблоне
  core: [13, 4, 50],    // ядро ЛОЦМАНа
  ai: [13, 5, 50],      // компьютер ИИ TM-AI
  nav: [10, 5, 50],     // штурманский модуль TM-NAV (командный компьютер)
  // генератор, ядро, плавильня, кабели, детектор, колонка: после установки обновить соседей (кабель увидит машины, модем — периферию)
  power: [[10, 3, 38], [10, 4, 38], [10, 5, 38], [10, 6, 38], [11, 3, 38], [11, 4, 50], [11, 6, 50], [12, 3, 38], [12, 3, 39], [12, 3, 40], [12, 3, 41], [12, 3, 42], [12, 3, 43], [12, 3, 44], [12, 3, 45], [12, 3, 46], [12, 3, 47], [12, 3, 48], [12, 3, 49], [13, 3, 49], [13, 3, 50], [13, 4, 49], [13, 4, 50]],
  coreCharge: 30000,     // FE: остаточный заряд при старте мира
  // подсыпка грунта: строка на каждый z, символ на каждый x — нижний блок шаблона в колонке ('a' = y0), '.' — не трогать
  fill: [
    '...........ccccc...........',
    '...........ccccc...........',
    '...........cbbbcc..........',
    '..........ccbbbcc..........',
    '..........dcbbbbcdc........',
    '..........dcbbbbcdc........',
    '.........ddcbbbbcd.........',
    '........cdcbbbbbcd.........',
    '.........ecbbbbbddc........',
    '........ddcbbbbcdc.........',
    '........debbbbbcdd.........',
    '.......cedbbbbbccd.........',
    '.......cddbbbbbbcd.........',
    '........ddcbbbbbcec........',
    '........ddcbbbbbcdc.g......',
    '.........cbaaaaaaed.gg.....',
    '.........ebaaaaaabdcggg....',
    '........cdbaaaaaabd.gggg...',
    '........debaaaaaabedgggg...',
    '........dfbaaaaaabedggg....',
    '........eebaaaaaabedgg.....',
    '.......deeaaaaaaaeedg......',
    '.......cebaaaaaabee........',
    '.......debaaaaaabed........',
    '.......efbaaaaaabed........',
    '.......eebaaaaaabee........',
    '.......eebaaaaaabee........',
    '.......eebaaaaaaabed.......',
    '.......debaaaaaaabed.......',
    '.......debaaaaaaabee.......',
    '.......debaaaaaaaaded......',
    '.......defaaaaaaaabee......',
    '.......ccfeeeeeeefccc......',
    '.......ccfeeeeeeef.cc......',
    '.......ccfeeeeeeefcc.......',
    '......cccfeeeeeeefc........',
    '.......ccfeeeeeeefcc.......',
    '......c.cfeeeeeeefccc......',
    '......c.cfdddeeeefccc......',
    '......cccfeedeeeef.........',
    '........efeedeeeef.c.......',
    '.......ccfeedeeeefc........',
    '......cccfeedeeeefc........',
    '......cccfeedeeeef.c.......',
    '.......ccfeedeeeef.c.......',
    '......ccceddddddde.cc......',
    '......c.cedddddddeccc......',
    '......c.ceddddddde.c.......',
    '.......cceddddddde.c.......',
    '.......cceddddddde.c.......',
    '......cccedddddddecc.......',
    '.......ddedddddddedd.......',
    '......ccdeedddddeedc.......',
    '.......ceffeeeeeffec.......',
    '........ceefffffff.........',
    '.........eefffffeec........',
    '........cdddeeeddd.........',
    '.........ccddeddd..........',
    '.........cddddddd..........',
    '..........ccddcc.c.........',
    '...........ccccc...........'
  ]
}
// </gen:capsule>

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

// ---------- выбор места: ровная площадка рядом с точкой мира ----------
// Высоты берём из шума генератора (getBaseHeight), не генерируя чанки. Это небыстро (с Tectonic ~15 мс на точку),
// поэтому: грубо — 5 точек на кандидата (кольцами от точки мира, пока не найдётся «отлично» или не кончится время),
// точно — для 4 лучших отпечаток шаблона вдоль и поперёк; корма/нос выбираются по тому, где ровнее под кораблём.
// Штраф: перепад высот, вода, «неудобные» биомы (лес, горы, болото), расстояние.
const TM_SITE = {
  radius: 400,      // насколько далеко от точки мира искать
  step: 40,         // шаг сетки кандидатов
  good: 2.5,        // оценка «отлично» — дальше не ищем
  budgetMs: 6000    // предел времени на грубый проход
}
const TmHeightmap = Java.loadClass('net.minecraft.world.level.levelgen.Heightmap$Types')
const TM_ROTS = ['none', 'clockwise_90', '180', 'counterclockwise_90']
const TM_LOW = 'abcdefghijklmnopqrstuvwxyz'
const TmPlaceSettings = Java.loadClass('net.minecraft.world.level.levelgen.structure.templatesystem.StructurePlaceSettings')
const TmBlockPos = Java.loadClass('net.minecraft.core.BlockPos')
const TmRotation = Java.loadClass('net.minecraft.world.level.block.Rotation')
const TM_ROTATION = { none: TmRotation.NONE, clockwise_90: TmRotation.CLOCKWISE_90, '180': TmRotation.CLOCKWISE_180,
  counterclockwise_90: TmRotation.COUNTERCLOCKWISE_90 }

function tmBiomePenalty(id) {
  const b = String(id)
  if (/ocean|river|lake/.test(b)) return 40
  if (/mushroom|volcan|crater/.test(b)) return 20
  if (/swamp|marsh|bog|mangrove|fen/.test(b)) return 12
  if (/peak|mountain|cliff|slope|crag|summit|alps|highland/.test(b)) return 10
  if (/jungle|rainforest/.test(b)) return 9
  if (/beach|shore|coast/.test(b)) return 6
  if (/forest|taiga|woods|grove|thicket|wood/.test(b)) return 6
  if (/frozen|snow|ice|glacier|tundra/.test(b)) return 4
  if (/desert|badlands|dune|mesa/.test(b)) return 2
  if (/plain|meadow|savanna|prairie|steppe|field|grass|shrub|pasture|valley/.test(b)) return -2
  return 0
}

// Оценка набора высот: перепад, разброс, вода. Чем меньше — тем лучше.
function tmFlatScore(hs, sea) {
  let sMin = 1e9, sMax = -1e9, sSum = 0, sWet = 0
  hs.forEach(h => { sMin = Math.min(sMin, h); sMax = Math.max(sMax, h); sSum += h; if (h < sea - 1) sWet++ })
  const mean = sSum / hs.length
  let sVar = 0
  hs.forEach(h => { sVar += (h - mean) * (h - mean) })
  return (sMax - sMin) * 1.5 + Math.sqrt(sVar / hs.length) * 3 + sWet * 6
}

function tmFindSite(level, sx, sz) {
  const src = level.getChunkSource()
  const gen = src.getGenerator()
  const rs = src.randomState()
  const sea = level.getSeaLevel()
  const hAt = (x, z) => gen.getBaseHeight(x, z, TmHeightmap.OCEAN_FLOOR_WG, level, rs)
  const biomeAt = (x, y, z) => {
    // без объявлений внутри try: Rhino KubeJS считает повторный вызов «redeclaration»
    try {
      return String(gen.getBiomeSource().getNoiseBiome(x >> 2, y >> 2, z >> 2, rs.sampler()).unwrapKey().orElse(null).location())
    } catch (err) {
      if (!tmFindSite.biomeWarned) { tmFindSite.biomeWarned = true; console.warn('[TM] biome lookup: ' + err) }
      return ''
    }
  }
  const t0 = Date.now()
  const cands = []
  for (let gx = -TM_SITE.radius; gx <= TM_SITE.radius; gx += TM_SITE.step) {
    for (let gz = -TM_SITE.radius; gz <= TM_SITE.radius; gz += TM_SITE.step) {
      if (gx * gx + gz * gz <= TM_SITE.radius * TM_SITE.radius) cands.push([sx + gx, sz + gz, Math.hypot(gx, gz)])
    }
  }
  cands.sort((p, q) => p[2] - q[2])
  const coarse = []
  for (let ci = 0; ci < cands.length; ci++) {
    if (Date.now() - t0 > TM_SITE.budgetMs && coarse.length >= 4) break
    let c = cands[ci]
    let mid = hAt(c[0], c[1])
    let hs = [mid, hAt(c[0] - 18, c[1] - 18), hAt(c[0] + 18, c[1] - 18), hAt(c[0] - 18, c[1] + 18), hAt(c[0] + 18, c[1] + 18)]
    let sc = tmFlatScore(hs, sea) + tmBiomePenalty(biomeAt(c[0], mid, c[1])) + c[2] / 96
    coarse.push([sc, c[0], c[1], c[2], biomeAt(c[0], mid, c[1])])
    if (sc <= TM_SITE.good) break
  }
  coarse.sort((p, q) => p[0] - q[0])
  // точно: отпечаток вдоль оси z (none/180) и вдоль x (по/против часовой) — общий набор точек на оба конца
  const W = CAPSULE.size[0], L = CAPSULE.size[2]
  let best = null
  coarse.slice(0, 4).forEach(c => {
    ;[['none', '180'], ['clockwise_90', 'counterclockwise_90']].forEach(pair => {
      let mid = tmRotXZ(pair[0], Math.floor(W / 2), Math.floor(L / 2))
      let ox = c[1] - mid[0], oz = c[2] - mid[1]
      let all = [], shipA = [], shipB = []
      for (let lz = 2; lz < L; lz += 8) {
        for (let lx = 4; lx < W; lx += 9) {
          let r = tmRotXZ(pair[0], lx, lz)
          let h = hAt(ox + r[0], oz + r[1])
          all.push(h)
          if (lz >= 28) shipA.push(h)            // корабль — у этого конца при первом повороте пары
          if (L - 1 - lz >= 28) shipB.push(h)    // … и у противоположного при втором
        }
      }
      let base = tmFlatScore(all, sea) * 0.6 + tmBiomePenalty(c[4]) + c[3] / 96
      ;[[pair[0], shipA], [pair[1], shipB]].forEach(v => {
        let sc = base + tmFlatScore(v[1], sea) * 0.6
        if (!best || sc < best.score) {
          let m2 = tmRotXZ(v[0], Math.floor(W / 2), Math.floor(L / 2))
          best = { score: sc, ox: c[1] - m2[0], oz: c[2] - m2[1], rot: v[0], cx: c[1], cz: c[2], biome: c[4] }
        }
      })
    })
  })
  console.info(`[TM] site search: ${coarse.length} candidates in ${Date.now() - t0} ms, best ${best ? JSON.stringify(best) : 'none'}`)
  return best
}

function tmPlaceCapsule(server) {
  const level = server.overworld()
  const spawn = level.sharedSpawnPos
  let site = null
  try {
    site = tmFindSite(level, spawn.x, spawn.z)
  } catch (err) {
    console.warn('[TM] site search failed: ' + err)
  }
  if (!site) {
    const fr = TM_ROTS[Math.floor(Math.random() * 4)]
    const fa = tmRotXZ(fr, CAPSULE.anchor[0], CAPSULE.anchor[2])
    site = { ox: spawn.x - fa[0], oz: spawn.z - fa[1], rot: fr }
  }
  const rot = site.rot, ox = site.ox, oz = site.oz
  // настоящая высота поверхности (чанки уже генерируются): медиана по зоне корабля
  const surf = []
  for (let lz = 30; lz <= 54; lz += 4) {
    for (let lx = 9; lx <= 17; lx += 4) {
      let rr = tmRotXZ(rot, lx, lz)
      level.getChunk((ox + rr[0]) >> 4, (oz + rr[1]) >> 4)       // сгенерировать чанк, иначе высота = дно мира
      surf.push(level.getHeight(TmHeightmap.MOTION_BLOCKING_NO_LEAVES, ox + rr[0], oz + rr[1]))
    }
  }
  surf.sort((p, q) => p - q)
  const sy = surf[Math.floor(surf.length / 2)]
  const oy = sy - CAPSULE.ground
  // деревья в отпечатке: стволы и листву над землёй убираем, чтобы не висели над кораблём и шлейфом
  for (let tz = 0; tz < CAPSULE.size[2]; tz++) {
    for (let tx = 0; tx < CAPSULE.size[0]; tx++) {
      if (String(CAPSULE.fill[tz]).substring(tx, tx + 1) === '.') continue
      let tr = tmRotXZ(rot, tx, tz)
      for (let ty = sy; ty < sy + 24; ty++) {
        let tb = level.getBlock(ox + tr[0], ty, oz + tr[1])
        if (tb.hasTag('minecraft:logs') || tb.hasTag('minecraft:leaves')) tb.set('minecraft:air')
      }
    }
  }
  // Ставим шаблон напрямую (как /place template, но без его проверки «участок загружен»: при повороте она
  // смотрит не тот прямоугольник, а место может быть вдали от точки мира). Чанки грузятся сами при установке.
  // (Rhino KubeJS не терпит объявлений внутри try — переменные объявлены заранее)
  let res = 'ok'
  let tpl = null, placeSettings = null, placePos = null
  try {
    tpl = level.getStructureManager().get(CAPSULE.id).orElse(null)
    if (!tpl) throw new Error('no template ' + CAPSULE.id)
    placeSettings = new TmPlaceSettings().setRotation(TM_ROTATION[rot])
    placePos = new TmBlockPos(ox, oy, oz)
    tpl.placeInWorld(level, placePos, placePos, placeSettings, level.getRandom(), 2)
  } catch (err) {
    res = 'api failed: ' + err + '; command: ' + server.runCommand(`execute in minecraft:overworld run place template ${CAPSULE.id} ${ox} ${oy} ${oz} ${rot}`)
  }
  console.info(`[TM] capsule at ${ox} ${oy} ${oz} rot=${rot} surface=${sy} (min ${surf[0]}, max ${surf[surf.length - 1]}) result=${res}`)

  // подсыпка: под нижним блоком шаблона в каждой колонке маски — грунт вместо пустоты/воды (до 12 блоков вниз)
  for (let fz = 0; fz < CAPSULE.size[2]; fz++) {
    for (let fx = 0; fx < CAPSULE.size[0]; fx++) {
      let low = TM_LOW.indexOf(String(CAPSULE.fill[fz]).substring(fx, fx + 1))
      if (low < 0) continue
      let fr = tmRotXZ(rot, fx, fz)
      for (let yf = oy + low - 1, nf = 0; nf < 12; yf--, nf++) {
        let fill = level.getBlock(ox + fr[0], yf, oz + fr[1])
        if (!fill.blockState.isAir() && !fill.blockState.liquid()) break
        fill.set('minecraft:dirt')
      }
    }
  }
  const at = p => { let q = tmRotXZ(rot, p[0], p[2]); return [ox + q[0], oy + p[1], oz + q[1]] }
  // шаблон ставится без обновления соседей: кабель Mekanism не видит плавильню и генератор, а проводной модем —
  // детектор игроков и колонку, пока их не «толкнуть»
  CAPSULE.power.forEach(pp => {
    let wp = at(pp)
    let bp = new TmBlockPos(wp[0], wp[1], wp[2])
    level.updateNeighborsAt(bp, level.getBlockState(bp).getBlock())
  })
  // остаточный заряд ядра ЛОЦМАНа: несколько минут работы до того, как экипаж разожжёт генератор
  try {
    let c = at(CAPSULE.core)
    let core = level.getBlock(c[0], c[1], c[2])
    if (core.id === 'kubejs:ai_core' && core.entity) {
      core.entity.attachments.get('energy').setEnergyStored(CAPSULE.coreCharge)
      core.entity.setChanged()
    }
    // для лога прогона: на месте ли ключевые блоки рубки
    let ai = at(CAPSULE.ai)
    let gn = at([CAPSULE.core[0], CAPSULE.core[1], CAPSULE.core[2] - 1])
    let mon = level.getBlock(ai[0], ai[1] + 1, ai[2])
    let monNbt = mon.entityData
    console.info(`[TM] capsule check: core=${core.id} ai=${level.getBlock(ai[0], ai[1], ai[2]).id} ` +
      `generator=${level.getBlock(gn[0], gn[1], gn[2]).id} monitor=${mon.id} ` +
      `${monNbt ? monNbt.getInt('Width') + 'x' + monNbt.getInt('Height') : '?'}`)
  } catch (err) {
    console.warn('[TM] core charge: ' + err)
  }
  // переезд ЛОЦМАНа (tm_ai_relocate.js): где стоит «свой» штурманский модуль и компьютер ИИ
  // (имена уникальные в пределах функции: Rhino не любит повторные let/const в одной функции)
  const navP = at(CAPSULE.nav)
  server.persistentData.putString('tm_nav_pos', `minecraft:overworld ${navP[0]} ${navP[1]} ${navP[2]}`)
  server.persistentData.putBoolean('tm_nav_known', true)
  const aiP = at(CAPSULE.ai)
  server.runCommandSilent(`data modify storage tm:ai ai_pos set value "minecraft:overworld ${aiP[0]} ${aiP[1]} ${aiP[2]}"`)

  const sp = at(CAPSULE.anchor)
  server.runCommandSilent(`setworldspawn ${sp[0]} ${sp[1]} ${sp[2]}`)
  server.persistentData.putString('tm_capsule_pos', `${sp[0]} ${sp[1]} ${sp[2]}`)
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
