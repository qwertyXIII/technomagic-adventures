// TechnoMagic Adventures — логика ядра ЛОЦМАНа (раз в секунду, tickFrequency 20).
// 1) Реальный расход энергии: IDLE + (сила редстоун-сигнала от компьютера) × PER_LEVEL FE/t.
//    Компьютер ИИ подаёт сигнал на ядро (сторона bottom), пока «думает» или сканирует (tmai.power_think_level).
//    В покое 2 FE/t, при запросе до 62 FE/t. Аварийный генератор капсулы (Powah, начальный) даёт 20 FE/t.
// 2) Детали ремонта в инвентаре ядра поднимают уровень ремонта (scoreboard #tm tm_ai_repair) —
//    авторитетный уровень: его читает штурманский модуль TM-NAV, программа Lua подделать его не может.
//    Ступени ставятся строго по порядку; деталь «на вырост» остаётся в ядре и встанет позже.
// 3) Всё прочее в ядре — сданное по поручениям — утилизируется.
// Числа держать в синхроне с ROM: tmai.power_min (2000 FE).

const AI_IDLE_FE = 2
const AI_PER_LEVEL_FE = 4

const AI_REPAIR = {
  'kubejs:ai_repair_cooling': { level: 1, text: 'контур охлаждения' },
  'kubejs:ai_repair_memory_1': { level: 2, text: 'блок памяти Мк1' },
  'kubejs:ai_repair_memory_2': { level: 3, text: 'блок памяти Мк2' },
  'kubejs:ai_repair_quantum': { level: 4, text: 'квантовый вычислитель' }
}

BlockEvents.blockEntityTick('kubejs:ai_core', event => {
  const block = event.block
  const be = block.entity
  if (!be) return
  const level = block.level
  const energy = be.attachments.get('energy')
  const signal = level.getBestNeighborSignal(block.pos)
  const drain = (AI_IDLE_FE + signal * AI_PER_LEVEL_FE) * 20
  // removeEnergy у KubeJS не ограничивает снизу (в тесте уходило в минус) — считаем сами
  energy.setEnergyStored(Math.max(0, energy.getEnergyStored() - drain))

  const inv = be.attachments.get('cargo')
  const server = level.server
  const pd = server.persistentData
  for (let slot = 0; slot < inv.slots; slot++) {
    let stack = inv.getStackInSlot(slot)
    if (stack.isEmpty()) continue
    let part = AI_REPAIR[stack.id]
    if (!part) {                      // сдано по поручению — утилизировать
      inv.setStackInSlot(slot, Item.empty)
      continue
    }
    let cur = pd.getInt('tm_ai_repair')
    if (part.level <= cur) { inv.setStackInSlot(slot, Item.empty); continue }   // уже стоит — лишняя деталь
    if (part.level !== cur + 1) continue                                         // рано: ждёт своей очереди
    pd.putInt('tm_ai_repair', part.level)
    server.runCommandSilent('scoreboard objectives add tm_ai_repair dummy')
    server.runCommandSilent(`scoreboard players set #tm tm_ai_repair ${part.level}`)
    server.tell(Text.aqua(`[Капсула] Ядро ЛОЦМАНа: установлен ${part.text}. Ремонт: ступень ${part.level} из 4.`))
    stack.shrink(1)
  }
})
