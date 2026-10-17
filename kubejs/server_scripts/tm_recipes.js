// TechnoMagic Adventures — изменённые рецепты: связки модов, «ворота» прогрессии, сюжетные крафты.
// KubeJS 2101.7 (MC 1.21.1, NeoForge). Принцип баланса: «немного дороже и связано», без гринда —
// каждое изменение добавляет 1–2 предмета из ДРУГОЙ ветки (техника ↔ магия ↔ трофеи боссов).
// Исходные рецепты удаляются по точному id (проверены по jar), новые получают id kubejs:...
// Полный список изменений и зачем — design/final-plan.md, раздел «Баланс».

ServerEvents.recipes(event => {
  const swap = id => event.remove({ id: id })

  // ───────────────────────── 1. ТЕХНИКА ← МАГИЯ ─────────────────────────
  // Металлургический наполнитель Mekanism: редстоун → исходные самоцветы Ars Nouveau
  swap('mekanism:metallurgic_infuser')
  event.shaped('mekanism:metallurgic_infuser', ['I#I', 'SOS', 'I#I'], {
    I: '#c:ingots/iron', '#': 'minecraft:furnace', S: 'ars_nouveau:source_gem', O: '#c:ingots/osmium'
  }).id('kubejs:mekanism/metallurgic_infuser')

  // Высекатель AE2: железо → стальные пластины
  swap('ae2:network/blocks/inscribers')
  event.shaped('ae2:inscriber', ['aba', 'c a', 'aba'], {
    a: '#c:plates/steel', b: 'minecraft:piston', c: '#c:ingots/copper'
  }).id('kubejs:ae2/inscriber')

  // МЭ-контроллер: нижний флюисовый кристалл → самоцвет, настроенный на духа (Occultism)
  swap('ae2:network/blocks/controller')
  event.shaped('ae2:controller', ['aba', 'bcb', 'ada'], {
    a: 'ae2:smooth_sky_stone_block', b: 'ae2:fluix_crystal', c: 'ae2:engineering_processor', d: 'occultism:spirit_attuned_gem'
  }).id('kubejs:ae2/controller')

  // ───────────────────────── 2. ТЕХНИКА ← ТРОФЕИ БОССОВ ─────────────────────────
  // Элитная схема Mekanism: + огненный слиток (Гидра, Сумеречный лес); выход ×2, чтобы не гриндить
  swap('mekanism:control_circuit/elite')
  event.shaped('2x mekanism:elite_control_circuit', ['AFA', 'CAC'], {
    A: '#mekanism:alloys/reinforced', F: 'twilightforest:fiery_ingot', C: '#c:circuits/advanced'
  }).id('kubejs:mekanism/elite_control_circuit')

  // Совершенная схема Mekanism: + игнитовый слиток (Игнис, Cataclysm); выход ×2
  swap('mekanism:control_circuit/ultimate')
  event.shaped('2x mekanism:ultimate_control_circuit', ['AIA', 'CAC'], {
    A: '#mekanism:alloys/atomic', I: 'cataclysm:ignitium_ingot', C: '#c:circuits/elite'
  }).id('kubejs:mekanism/ultimate_control_circuit')

  // Контроллер термоядерного реактора: стеклянные панели → игнитовые слитки
  swap('mekanismgenerators:reactor/controller')
  event.shaped('mekanismgenerators:fusion_reactor_controller', ['CGC', 'FTF', 'FFF'], {
    C: '#c:circuits/ultimate', G: 'cataclysm:ignitium_ingot', F: 'mekanismgenerators:fusion_reactor_frame', T: 'mekanism:basic_chemical_tank'
  }).id('kubejs:mekanism/fusion_reactor_controller')

  // Антипротонный нуклеосинтезатор: антиматерия → пустотные шипы (Пустотный цветок, BOMD) — трофей вместо многочасового SPS
  swap('mekanism:antiprotonic_nucleosynthesizer')
  event.shaped('mekanism:antiprotonic_nucleosynthesizer', ['#C#', 'AXA', '#C#'], {
    '#': 'mekanism:alloy_atomic', C: '#c:circuits/ultimate', A: 'bosses_of_mass_destruction:void_thorn', X: 'mekanism:steel_casing'
  }).id('kubejs:mekanism/antiprotonic_nucleosynthesizer')

  // Ядро слияния Draconic Evolution: алмазы → огненные слитки
  swap('draconicevolution:machines/crafting_core')
  event.shaped('draconicevolution:crafting_core', ['ABA', 'BCB', 'ABA'], {
    A: '#c:storage_blocks/lapis', B: 'twilightforest:fiery_ingot', C: 'draconicevolution:draconium_core'
  }).id('kubejs:draconicevolution/crafting_core')

  // Усиленный контроллер Extreme Reactors: алмазный блок → урановый стержень Alex's Caves
  event.remove({ id: 'bigreactors:reactor/reinforced/controller_ingots_yellorium' })
  event.remove({ id: 'bigreactors:reactor/reinforced/controller_ingots_uranium' })
  event.shaped('bigreactors:reinforced_reactorcontroller', ['CXC', 'YDY', 'CRC'], {
    C: 'bigreactors:reinforced_reactorcasing', X: 'minecraft:comparator', Y: '#c:ingots/yellorium', D: 'alexscaves:uranium_rod', R: '#c:dusts/redstone'
  }).id('kubejs:bigreactors/reinforced_reactorcontroller')

  // Алтарь пробуждения Mystical Agriculture: оранжевая шерсть → древняя душа (Ночной лич, BOMD)
  swap('mysticalagriculture:awakening_altar')
  event.shaped('mysticalagriculture:awakening_altar', ['GCG', ' S ', 'SSS'], {
    G: '#c:ingots/gold', C: 'bosses_of_mass_destruction:ancient_anima', S: 'mysticalagriculture:soulstone'
  }).id('kubejs:mysticalagriculture/awakening_altar')

  // ───────────────────────── 3. МАГИЯ ← ТЕХНИКА ─────────────────────────
  // Чародейский аппарат Ars Nouveau: золото → латунь Create
  swap('ars_nouveau:enchanting_apparatus')
  event.shaped('ars_nouveau:enchanting_apparatus', ['nsn', 'gdg', 'nsn'], {
    n: '#c:nuggets/gold', s: 'ars_nouveau:sourcestone', g: '#c:ingots/brass', d: '#c:gems/diamond'
  }).id('kubejs:ars_nouveau/enchanting_apparatus')

  // Волшебная наковальня Iron's Spells: глубинный сланец → стальные пластины
  swap('irons_spellbooks:arcane_anvil')
  event.shaped('irons_spellbooks:arcane_anvil', ['AAA', ' D ', 'SVS'], {
    A: 'minecraft:amethyst_block', D: '#c:gems/diamond', S: '#c:plates/steel', V: 'minecraft:anvil'
  }).id('kubejs:irons_spellbooks/arcane_anvil')

  // Тигель духов Malum: + 4 стальные пластины в настой
  swap('malum:spirit_infusion/spirit_crucible')
  event.custom({
    type: 'malum:spirit_infusion',
    input: { count: 1, item: 'minecraft:furnace' },
    extraInputs: [
      { count: 2, item: 'malum:hex_ash' },
      { count: 8, item: 'malum:tainted_rock' },
      { count: 8, item: 'malum:twisted_rock' },
      { count: 4, item: 'immersiveengineering:plate_steel' }
    ],
    result: { count: 1, id: 'malum:spirit_crucible' },
    spirits: [{ type: 'malum:infernal', count: 8 }, { type: 'malum:aqueous', count: 8 }]
  }).id('kubejs:malum/spirit_crucible')

  // Печь кальцинации Theurgy: железо → латунь
  swap('theurgy:crafting/shaped/calcination_oven')
  event.shaped('theurgy:calcination_oven', [' I ', 'ICI', ' I '], {
    I: '#c:ingots/brass', C: '#c:storage_blocks/copper'
  }).id('kubejs:theurgy/calcination_oven')

  // Ara Vitae (алтарь крови Neo Vitae): золото → стальные пластины
  swap('neovitae:ara_vitae')
  event.shaped('neovitae:ara_vitae', ['s s', 'sfs', 'ggg'], {
    s: '#neovitae:vitae_stone', f: 'minecraft:furnace', g: '#c:plates/steel'
  }).id('kubejs:neovitae/ara_vitae')

  // Основа хранилища Occultism (ритуал фолиота): медь → флюисовые кристаллы AE2
  swap('occultism:ritual/craft_storage_controller_base')
  event.custom({
    type: 'occultism:ritual',
    activation_item: { item: 'occultism:book_of_binding_bound_foliot' },
    duration: 60,
    ingredients: [{ item: 'occultism:otherstone_pedestal' }, { item: 'ae2:fluix_crystal' }, { item: 'ae2:fluix_crystal' }, { tag: 'c:ingots/gold' }],
    pentacle_id: 'occultism:craft_foliot',
    result: { count: 1, id: 'occultism:storage_controller_base' },
    ritual_dummy: { count: 1, id: 'occultism:ritual_dummy/craft_storage_controller_base' },
    ritual_type: 'occultism:craft'
  }).id('kubejs:occultism/ritual/craft_storage_controller_base')

  // ───────────────────────── 4. КИБЕРИМПЛАНТЫ, РЕПЛИКАЦИЯ ─────────────────────────
  swap('cyber_ware_port:surgery_chamber')
  event.shaped('cyber_ware_port:surgery_chamber', ['IDI', 'IBI', 'IRI'], {
    I: '#c:plates/steel', D: 'minecraft:iron_trapdoor', B: '#minecraft:beds', R: 'mekanism:basic_control_circuit'
  }).id('kubejs:cyberware/surgery_chamber')

  swap('cyber_ware_port:cyberware_workbench')
  event.shaped('cyber_ware_port:cyberware_workbench', ['III', 'ICI', 'IPI'], {
    I: '#c:ingots/steel', C: 'minecraft:crafting_table', P: 'immersiveengineering:circuit_board'
  }).id('kubejs:cyberware/cyberware_workbench')

  // Репликатор материи — после совершенных схем Mekanism
  swap('replication:replicator')
  event.shaped('replication:replicator', ['IP ', 'IRM', 'III'], {
    I: 'replication:replica_ingot', P: 'minecraft:piston', R: 'mekanism:ultimate_control_circuit', M: '#c:ingots/iron'
  }).id('kubejs:replication/replicator')

  // ───────────────────────── 5. КОСМОС И ТРАНСПОРТ ─────────────────────────
  // Верстак НАСА: факелы → продвинутые схемы Mekanism
  swap('ad_astra:nasa_workbench')
  event.shaped('ad_astra:nasa_workbench', ['|#|', 'TCT', '#B#'], {
    '|': '#ad_astra:iron_rods', '#': '#ad_astra:steel_plates', T: 'mekanism:advanced_control_circuit',
    C: 'minecraft:crafting_table', B: '#ad_astra:steel_blocks'
  }).id('kubejs:ad_astra/nasa_workbench')

  // Двигатели ракет: каждый уровень — новая ветка (Create → Mekanism → Сумеречный лес → Draconic)
  swap('ad_astra:steel_engine')
  event.shaped('ad_astra:steel_engine', ['###', '#E#', 'PFP'], {
    '#': '#ad_astra:steel_plates', E: 'ad_astra:engine_frame', F: 'ad_astra:fan', P: 'createdieselgenerators:engine_piston'
  }).id('kubejs:ad_astra/steel_engine')
  swap('ad_astra:desh_engine')
  event.shaped('ad_astra:desh_engine', ['###', '#E#', 'AFA'], {
    '#': '#ad_astra:desh_plates', E: 'ad_astra:steel_engine', F: 'ad_astra:fan', A: 'mekanism:alloy_reinforced'
  }).id('kubejs:ad_astra/desh_engine')
  swap('ad_astra:ostrum_engine')
  event.shaped('ad_astra:ostrum_engine', ['###', '#E#', 'AFA'], {
    '#': '#ad_astra:ostrum_plates', E: 'ad_astra:desh_engine', F: 'ad_astra:fan', A: 'twilightforest:fiery_ingot'
  }).id('kubejs:ad_astra/ostrum_engine')
  swap('ad_astra:calorite_engine')
  event.shaped('ad_astra:calorite_engine', ['###', '#E#', ' FW'], {
    '#': '#ad_astra:calorite_plates', E: 'ad_astra:ostrum_engine', F: 'ad_astra:fan', W: 'draconicevolution:wyvern_core'
  }).id('kubejs:ad_astra/calorite_engine')

  // Двигатель Immersive Aircraft: поршни → поршни двигателя Create Diesel Generators
  swap('immersive_aircraft:engine')
  event.shaped('immersive_aircraft:engine', [' C ', 'PFP', 'CIC'], {
    C: 'minecraft:cobblestone', P: 'createdieselgenerators:engine_piston', F: 'minecraft:blast_furnace', I: 'immersive_aircraft:boiler'
  }).id('kubejs:immersive_aircraft/engine')

  // ───────────────────────── 7. СВЯЗЬ ЛОЦМАНа: эндер-модем — поздняя техника ─────────────────────────
  swap('computercraft:wireless_modem_advanced')
  event.shaped('computercraft:wireless_modem_advanced', ['GBG', 'QMQ', 'GWG'], {
    G: '#c:ingots/gold', B: 'minecraft:dragon_breath', Q: 'ae2:quantum_entangled_singularity',
    M: 'computercraft:wireless_modem_normal', W: 'draconicevolution:wyvern_core'
  }).id('kubejs:computercraft/wireless_modem_advanced')

  // ───────────────────────── 8. SOLAR FLUX: панели 5–8 и панели под AvaritiaNeo ─────────────────────────
  // Оригинальные рецепты 5–8 выключены в config/solarflux/recipes.cfg (их вставляет HammerLib мимо датапаков).
  event.shaped('2x solarflux:sp_5', ['ppp', 'scs', 'sbs'], {
    p: 'solarflux:photovoltaic_cell_3', s: 'solarflux:sp_4', c: 'ars_nouveau:source_gem_block', b: '#c:storage_blocks/gold'
  }).id('kubejs:solarflux/sp_5')
  event.shaped('2x solarflux:sp_6', ['ppp', 'scs', 'sbs'], {
    p: 'solarflux:photovoltaic_cell_4', s: 'solarflux:sp_5', c: 'ad_astra:photovoltaic_etrium_cell', b: '#c:storage_blocks/diamond'
  }).id('kubejs:solarflux/sp_6')
  event.shaped('2x solarflux:sp_7', ['ppp', 'scs', 'sbs'], {
    p: 'solarflux:photovoltaic_cell_5', s: 'solarflux:sp_6', c: 'mekanism:ultimate_control_circuit', b: 'powah:nitro_crystal_block'
  }).id('kubejs:solarflux/sp_7')
  event.shaped('2x solarflux:sp_8', ['ppp', 'scs', 'sbs'], {
    p: 'solarflux:photovoltaic_cell_6', s: 'solarflux:sp_7', c: 'draconicevolution:wyvern_core', b: 'ad_astra:calorite_block'
  }).id('kubejs:solarflux/sp_8')
  // Solar Flux собран под другой порт Avaritia — у его Avaritia-панелей нет рецептов. Делаем на экстремальном верстаке AvaritiaNeo.
  event.custom({
    type: 'avaritia:extreme_shaped',
    result: { id: 'solarflux:sp_avaritia.neutronium', count: 2 },
    pattern: ['  nn nn  ', ' nccsccn ', 'nc  g  cn', 'nc ppp cn', ' sgpdpgs ', 'nc ppp cn', 'nc  g  cn', ' nccsccn ', '  nn nn  '],
    key: {
      n: { item: 'avaritia:neutronium_ingot' }, c: { item: 'avaritia:crystal_matrix_ingot' }, g: { item: 'avaritia:neutron_nugget' },
      p: { item: 'avaritia:neutron_pile' }, s: { item: 'solarflux:sp_8' }, d: { item: 'solarflux:sp_de.chaotic' }
    }
  }).id('kubejs:solarflux/sp_avaritia_neutronium')
  event.custom({
    type: 'avaritia:extreme_shaped',
    result: { id: 'solarflux:sp_avaritia.infinity', count: 2 },
    pattern: ['  nn nn  ', ' nccsccn ', 'nc  g  cn', 'nc pip cn', ' sgiFigs ', 'nc pip cn', 'nc  g  cn', ' nccsccn ', '  nn nn  '],
    key: {
      n: { item: 'avaritia:neutronium_ingot' }, c: { item: 'avaritia:crystal_matrix_ingot' }, g: { item: 'avaritia:neutron_nugget' },
      p: { item: 'avaritia:neutron_pile' }, i: { item: 'avaritia:infinity_ingot' }, F: { item: 'solarflux:sp_avaritia.neutronium' },
      s: { item: 'avaritia:neutronium_block' }
    }
  }).id('kubejs:solarflux/sp_avaritia_infinity')

  // ───────────────────────── 9. AVARITIA NEO: эндгейм без многочасового гринда ─────────────────────────
  swap('avaritia:extreme_crafting_table')
  event.shaped('avaritia:extreme_crafting_table', ['IAI', 'ICI', 'IAI'], {
    I: 'avaritia:crystal_matrix_ingot', A: 'draconicevolution:awakened_core', C: 'avaritia:double_compressed_crafting_table'
  }).id('kubejs:avaritia/extreme_crafting_table')

  swap('avaritia:neutron_collector')
  event.custom({
    type: 'avaritia:extreme_shaped',
    result: { id: 'avaritia:neutron_collector' },
    pattern: ['IIQQAQQII', 'I QQAQQ I', 'I  RRR  I', 'X RRRRR X', 'I RRXRR I', 'X RRRRR X', 'I  RRR  I', 'I       I', 'IIIXIXIII'],
    key: {
      I: { tag: 'c:storage_blocks/iron' }, X: { item: 'avaritia:crystal_matrix_ingot' }, R: { tag: 'c:storage_blocks/redstone' },
      Q: { item: 'minecraft:quartz_block' }, A: { item: 'mekanism:pellet_antimatter' }
    }
  }).id('kubejs:avaritia/neutron_collector')

  // Катализатор бесконечности — только через Сингулярность бесконечности, а в ней — «коллекция трофеев» девяти боссов
  event.remove({ id: 'avaritia:infinity_catalyst' })
  swap('avaritia:infinity_singularity')
  event.custom({
    type: 'avaritia:extreme_shapeless',
    result: { id: 'avaritia:infinity_singularity' },
    singularities: true,
    ingredients: [
      { item: 'cataclysm:ignitium_ingot' }, { item: 'cataclysm:cursium_ingot' }, { item: 'cataclysm:witherite_ingot' },
      { item: 'cataclysm:ancient_metal_ingot' }, { item: 'bosses_of_mass_destruction:ancient_anima' },
      { item: 'bosses_of_mass_destruction:void_thorn' }, { item: 'twilightforest:ur_ghast_trophy' },
      { item: 'twilightforest:snow_queen_trophy' }, { item: 'mowziesmobs:sol_visage' }
    ]
  }).id('kubejs:avaritia/infinity_singularity')

  // Компрессор: сингулярности вдвое дешевле
  const sing = {
    iron: ['tag', 'c:storage_blocks/iron', 200], copper: ['tag', 'c:storage_blocks/copper', 200],
    gold: ['tag', 'c:storage_blocks/gold', 100], diamond: ['tag', 'c:storage_blocks/diamond', 120],
    emerald: ['tag', 'c:storage_blocks/emerald', 100], lapis: ['tag', 'c:storage_blocks/lapis', 100],
    redstone: ['tag', 'c:storage_blocks/redstone', 100], netherite: ['tag', 'c:storage_blocks/netherite', 64],
    quartz: ['item', 'minecraft:quartz_block', 100], amethyst: ['item', 'minecraft:amethyst_block', 100]
  }
  Object.keys(sing).forEach(k => {
    const ingredient = {}
    ingredient[sing[k][0]] = sing[k][1]
    event.remove({ id: 'avaritia:' + k + '_singularity' })
    event.custom({
      type: 'avaritia:compressor', result: { id: 'avaritia:' + k + '_singularity' }, cost: sing[k][2], ingredients: [ingredient]
    }).id('kubejs:avaritia/' + k + '_singularity')
  })

  // ───────────────────────── 10. СЮЖЕТ И ЛОЦМАН ─────────────────────────
  // Починка бортового самописца (ключ первого слоя памяти ЛОЦМАНа): Create + Immersive Engineering
  event.shaped('kubejs:flight_recorder', ['ATA', 'CBC', 'ATA'], {
    A: 'create:andesite_alloy', T: 'create:electron_tube', C: 'immersiveengineering:component_iron', B: 'kubejs:flight_recorder_broken'
  }).id('kubejs:story/flight_recorder')

  // Расшифрованный образец: пыльца Пустотного цветка + магия + вычислитель AE2
  event.shaped('kubejs:lethe_sample', [' V ', 'EPE', ' B '], {
    V: 'bosses_of_mass_destruction:void_lily', E: 'irons_spellbooks:arcane_essence', P: 'ae2:calculation_processor', B: 'minecraft:glass_bottle'
  }).id('kubejs:story/lethe_sample')

  // Финал А — путь техники
  event.shaped('kubejs:lethe_two_primed', ['LAL', 'ECE', 'EWE'], {
    L: 'bosses_of_mass_destruction:void_lily', A: 'mekanism:pellet_antimatter', E: 'minecraft:echo_shard',
    C: 'kubejs:lethe_two', W: 'draconicevolution:wyvern_core'
  }).id('kubejs:story/lethe_two_primed')

  // Финал Б — путь магии (сфера крови расходуется)
  event.shaped('kubejs:mnemosyne_core', ['EME', 'OLD', 'EXS'], {
    E: 'minecraft:emerald_block', M: 'malum:sacred_spirit', O: 'neovitae:blood_orb_master', L: 'kubejs:locman_core',
    D: 'kubejs:deep_song', X: 'enderio:xp_juice_bucket', S: 'theurgy:alchemical_sulfur_echo'
  }).id('kubejs:story/mnemosyne_core')

  // Финал В — путь бесконечности
  event.shaped('kubejs:infinite_resonator', ['ITI', 'DCQ', 'IKI'], {
    I: 'avaritia:infinity_ingot', T: 'cyber_ware_port:brain_upgrades_consciousness_transmitter', D: 'kubejs:deep_song',
    C: 'avaritia:infinity_catalyst', Q: 'kubejs:lethe_two', K: 'minecraft:emerald_block'
  }).id('kubejs:story/infinite_resonator')

  // Ремонт ядра ЛОЦМАНа (штурманский модуль): четыре ступени, каждая — стык модов
  event.shaped('kubejs:ai_repair_cooling', ['CPC', 'IWI', 'CPC'], {
    C: '#c:ingots/copper', P: 'create:fluid_pipe', I: 'minecraft:packed_ice', W: 'minecraft:water_bucket'
  }).id('kubejs:ai/repair_cooling')
  event.shaped('kubejs:ai_repair_memory_1', ['LSL', 'BGB', 'LSL'], {
    L: 'ae2:logic_processor', S: 'ars_nouveau:source_gem', B: 'mekanism:basic_control_circuit', G: 'immersiveengineering:circuit_board'
  }).id('kubejs:ai/repair_memory_1')
  event.shaped('kubejs:ai_repair_memory_2', ['EAE', 'PKP', 'EAE'], {
    E: 'ae2:engineering_processor', A: 'mekanism:advanced_control_circuit', P: 'malum:soul_stained_steel_ingot', K: 'ae2:cell_component_16k'
  }).id('kubejs:ai/repair_memory_2')
  event.shaped('kubejs:ai_repair_quantum', ['VEV', 'DKD', 'VEV'], {
    V: 'enderio:vibrant_crystal', E: 'mekanism:elite_control_circuit', D: 'draconicevolution:draconium_core', K: 'ae2:cell_component_64k'
  }).id('kubejs:ai/repair_quantum')

  // Модуль переноса (переезд ЛОЦМАНа: штурманский модуль и ядро; tm_ai_relocate.js) — ранний этап, без машин и магии:
  // 2 железных слитка, 2 проводных модема CC, сундук
  event.shaped('kubejs:ai_transfer_module', [' I ', 'MCM', ' I '], {
    I: '#c:ingots/iron', M: 'computercraft:wired_modem', C: '#c:chests/wooden'
  }).id('kubejs:ai/transfer_module')
})

// Теги: Alex's Caves 2.0.10 кладёт свои теги в старое пространство neoforge:* — его уран и сера не попадали в c:*
ServerEvents.tags('item', event => {
  event.add('c:raw_materials/uranium', 'alexscaves:uranium')
  event.add('c:storage_blocks/uranium', 'alexscaves:block_of_uranium')
  event.add('c:dusts/sulfur', 'alexscaves:sulfur_dust')
})
