// TechnoMagic Adventures — ядро бортового ИИ (ЛОЦМАН) в рубке капсулы.
// kubejs:ai_core — неразрушимый блок с FE-хранилищем (100 000 FE, принимает до 400 FE/t, наружу не отдаёт)
// и инвентарём на 9 слотов (детали ремонта и предметы, сданные по поручениям). Тик раз в секунду —
// логика в server_scripts/tm_ai_core.js. Для CC: Tweaked это generic-периферия «kubejs:ai_core»
// (getEnergy, getEnergyCapacity, list, pushItems…) — проверено в игре.

StartupEvents.registry('block', event => {
  event.create('ai_core')
    .soundType('metal')
    .unbreakable()
    .lightLevel(0.4)
    .texture('minecraft:block/respawn_anchor_top_off')
    .blockEntity(be => {
      be.energyStorage('energy', [], 100000, 400, 0, 0)   // id, стороны (все), ёмкость, приём/т, отдача/т, автовывод
      be.inventory('cargo', [], 9, 1)                      // id, стороны, ширина, высота
      be.serverTicking()
      be.tickFrequency(20)
    })
})
