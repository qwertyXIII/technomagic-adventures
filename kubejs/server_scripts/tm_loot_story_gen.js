// СГЕНЕРИРОВАНО tools/gen/build.py из tools/gen/lore.py — не править вручную.

// Сюжетные находки как дополнительный лут (повтор: основная выдача — награды квестов).
// LootJS 3.7 (1.21.1). Модификаторы срабатывают и для сундуков Lootr (у каждого игрока свой лут).

LootJS.modifiers(event => {
  event.addTableModifier('minecraft:chests/village/village_cartographer').addLoot(LootEntry.of('kubejs:untitled_book').when(c => c.randomChance(0.25)))
  event.addTableModifier('minecraft:chests/village/village_temple').addLoot(LootEntry.of('kubejs:untitled_book').when(c => c.randomChance(0.25)))
  event.addTableModifier('minecraft:chests/village/village_plains_house').addLoot(LootEntry.of('kubejs:untitled_book').when(c => c.randomChance(0.05)))
  event.addTableModifier('minecraft:chests/pillager_outpost').addLoot(LootEntry.of('kubejs:raider_order').when(c => c.randomChance(0.5)))
  event.addTableModifier('minecraft:chests/abandoned_mineshaft').addLoot(LootEntry.of('kubejs:shift_list').when(c => c.randomChance(0.1)))
  event.addTableModifier('minecraft:chests/nether_bridge').addLoot(LootEntry.of('kubejs:scorched_journal').when(c => c.randomChance(0.2)))
  event.addTableModifier('minecraft:chests/ancient_city').addLoot(LootEntry.of('kubejs:echo_chronicle').when(c => c.randomChance(0.15)))
  event.addTableModifier('minecraft:chests/stronghold_library').addLoot(LootEntry.of('kubejs:pilgrim_guide').when(c => c.randomChance(0.3)))
  event.addTableModifier('minecraft:chests/end_city_treasure').addLoot(LootEntry.of('kubejs:station_log').when(c => c.randomChance(0.2)))
  event.addTableModifier('minecraft:chests/trial_chambers/intersection').addLoot(LootEntry.of('kubejs:glagol_tablet').when(c => c.randomChance(0.15)))
  event.addTableModifier('minecraft:chests/village/village_temple').addLoot(LootEntry.of('kubejs:glagol_tablet').when(c => c.randomChance(0.1)))
})
