// TechnoMagic: огнестрел TACZ требует сталь, механизмы IE/Create и пластик (дюропласт IE из нефтехимии).
// Сгенерировано из tacz/tacz_default_gun/data/tacz/recipe/gun/*.json (ганпак по умолчанию, TACZ 1.1.8-hotfix-r7).
// Правило: железо N -> #c:ingots/steel ceil(N/2) + IE стальной мех. компонент round(N/32) (мин. 1);
//          лазурит N -> #c:plates/plastic ceil(N/3) (immersiveengineering:plate_duroplast);
//          стволы с огненными стержнями (снайперки/пулемёты) -> + create:precision_mechanism.
// Остальные материалы (золото, алмазы, огненные стержни, незерит, кварц, брёвна) — без изменений.
// Рецепты ганпака лежат в обычном датапаке (TACZ добавляет пак "tacz_resources"), поэтому KubeJS их видит:
// id вида tacz:gun/<имя>. Тип рецепта не имеет схемы KubeJS -> только event.custom().

function tacz(e, name, materials, result) {
  e.remove({ id: 'tacz:gun/' + name })
  e.custom({
    type: 'tacz:gun_smith_table_crafting',
    materials: materials,
    result: result
  }).id('kubejs:tacz/gun/' + name)
}

ServerEvents.recipes(e => {
  // Оружейный верстак: сталь вместо железа, стальной механический компонент IE вместо железного блока
  e.remove({ id: 'tacz:gun_smith_table' })
  e.shaped('tacz:gun_smith_table', ['LLL', 'SCS', 'S S'], {
    L: '#minecraft:logs',
    S: '#c:ingots/steel',
    C: 'immersiveengineering:component_steel'
  }).id('kubejs:tacz/gun_smith_table')

  // aa12: было #c:ingots/gold×16 + #c:ingots/iron×80 + #c:gems/diamond×2 + #c:rods/blaze×4
  tacz(e, 'aa12', [
      { item: {"tag": "c:ingots/steel"}, count: 40 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 16 },
      { item: {"tag": "c:gems/diamond"}, count: 2 },
      { item: {"tag": "c:rods/blaze"}, count: 4 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:aa12"})

  // ai_awp: было #c:gems/diamond×10 + #c:ingots/gold×50 + #c:ingots/iron×200 + #c:rods/blaze×5
  tacz(e, 'ai_awp', [
      { item: {"tag": "c:ingots/steel"}, count: 100 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 6 },
      { item: {"tag": "c:gems/diamond"}, count: 10 },
      { item: {"tag": "c:ingots/gold"}, count: 50 },
      { item: {"tag": "c:rods/blaze"}, count: 5 },
      { item: {"item": "create:precision_mechanism"}, count: 2 }
    ], {"type": "gun", "id": "tacz:ai_awp", "attachments": {"scope": "tacz:scope_contender"}})

  // ak47: было #c:ingots/iron×38 + #c:gems/lapis×6 + #minecraft:logs×10
  tacz(e, 'ak47', [
      { item: {"tag": "c:ingots/steel"}, count: 19 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "minecraft:logs"}, count: 10 }
    ], {"type": "gun", "id": "tacz:ak47"})

  // aug: было #c:ingots/iron×39 + #c:gems/lapis×8 + #minecraft:logs×6 + #c:gems/amethyst×1
  tacz(e, 'aug', [
      { item: {"tag": "c:ingots/steel"}, count: 20 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "minecraft:logs"}, count: 6 },
      { item: {"tag": "c:gems/amethyst"}, count: 1 }
    ], {"type": "gun", "id": "tacz:aug"})

  // b93r: было #c:ingots/iron×21 + #minecraft:logs×5 + #c:gems/lapis×2
  tacz(e, 'b93r', [
      { item: {"tag": "c:ingots/steel"}, count: 11 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 5 }
    ], {"type": "gun", "id": "tacz:b93r"})

  // cz75: было #c:ingots/iron×17
  tacz(e, 'cz75', [
      { item: {"tag": "c:ingots/steel"}, count: 9 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 }
    ], {"type": "gun", "id": "tacz:cz75"})

  // db_long: было #c:ingots/iron×14 + #minecraft:logs×10
  tacz(e, 'db_long', [
      { item: {"tag": "c:ingots/steel"}, count: 7 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 10 }
    ], {"type": "gun", "id": "tacz:db_long"})

  // db_short: было #c:ingots/iron×8 + #minecraft:logs×6
  tacz(e, 'db_short', [
      { item: {"tag": "c:ingots/steel"}, count: 4 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 6 }
    ], {"type": "gun", "id": "tacz:db_short"})

  // deagle: было #c:gems/diamond×2 + #c:ingots/gold×6 + #c:ingots/iron×42 + #c:rods/blaze×1
  tacz(e, 'deagle', [
      { item: {"tag": "c:ingots/steel"}, count: 21 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:gems/diamond"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 6 },
      { item: {"tag": "c:rods/blaze"}, count: 1 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:deagle"})

  // deagle_golden: было #c:gems/diamond×1 + #c:ingots/gold×32 + #c:ingots/iron×16 + #c:rods/blaze×1
  tacz(e, 'deagle_golden', [
      { item: {"tag": "c:ingots/steel"}, count: 8 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:gems/diamond"}, count: 1 },
      { item: {"tag": "c:ingots/gold"}, count: 32 },
      { item: {"tag": "c:rods/blaze"}, count: 1 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:deagle_golden"})

  // fn_evolys: было #c:gems/diamond×6 + #c:ingots/gold×30 + #c:ingots/iron×145 + #c:rods/blaze×5
  tacz(e, 'fn_evolys', [
      { item: {"tag": "c:ingots/steel"}, count: 73 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 5 },
      { item: {"tag": "c:gems/diamond"}, count: 6 },
      { item: {"tag": "c:ingots/gold"}, count: 30 },
      { item: {"tag": "c:rods/blaze"}, count: 5 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:fn_evolys"})

  // fn_fal: было #c:ingots/iron×64 + #c:gems/lapis×20 + #minecraft:logs×30 + #c:ingots/gold×10
  tacz(e, 'fn_fal', [
      { item: {"tag": "c:ingots/steel"}, count: 32 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 7 },
      { item: {"tag": "minecraft:logs"}, count: 30 },
      { item: {"tag": "c:ingots/gold"}, count: 10 }
    ], {"type": "gun", "id": "tacz:fn_fal"})

  // g36k: было #c:ingots/gold×16 + #c:ingots/iron×64 + #c:gems/quartz×8
  tacz(e, 'g36k', [
      { item: {"tag": "c:ingots/steel"}, count: 32 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 16 },
      { item: {"tag": "c:gems/quartz"}, count: 8 }
    ], {"type": "gun", "id": "tacz:g36k"})

  // glock_17: было #c:ingots/iron×16
  tacz(e, 'glock_17', [
      { item: {"tag": "c:ingots/steel"}, count: 8 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 }
    ], {"type": "gun", "id": "tacz:glock_17"})

  // hk416d: было #c:ingots/gold×16 + #c:ingots/iron×64 + #c:gems/quartz×8
  tacz(e, 'hk416d', [
      { item: {"tag": "c:ingots/steel"}, count: 32 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 16 },
      { item: {"tag": "c:gems/quartz"}, count: 8 }
    ], {"type": "gun", "id": "tacz:hk416d", "attachments": {"stock": "tacz:stock_hk_slim_line"}})

  // hk_g3: было #c:ingots/gold×9 + #c:ingots/iron×72 + #c:gems/quartz×5
  tacz(e, 'hk_g3', [
      { item: {"tag": "c:ingots/steel"}, count: 36 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 9 },
      { item: {"tag": "c:gems/quartz"}, count: 5 }
    ], {"type": "gun", "id": "tacz:hk_g3"})

  // hk_mk23: было #c:ingots/gold×4 + #c:ingots/iron×36 + #c:gems/lapis×2
  tacz(e, 'hk_mk23', [
      { item: {"tag": "c:ingots/steel"}, count: 18 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 1 },
      { item: {"tag": "c:ingots/gold"}, count: 4 }
    ], {"type": "gun", "id": "tacz:hk_mk23"})

  // hk_mp5a5: было #c:ingots/iron×36 + #c:gems/lapis×4
  tacz(e, 'hk_mp5a5', [
      { item: {"tag": "c:ingots/steel"}, count: 18 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 2 }
    ], {"type": "gun", "id": "tacz:hk_mp5a5"})

  // kar98: было #minecraft:logs×40 + #c:ingots/iron×28 + #c:ingots/gold×4 + #c:gems/lapis×12
  tacz(e, 'kar98', [
      { item: {"tag": "c:ingots/steel"}, count: 14 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 4 },
      { item: {"tag": "minecraft:logs"}, count: 40 },
      { item: {"tag": "c:ingots/gold"}, count: 4 }
    ], {"type": "gun", "id": "tacz:kar98"})

  // lonetrail: было #c:gems/lapis×20 + #c:ingots/gold×4 + #c:ingots/iron×40
  tacz(e, 'lonetrail', [
      { item: {"tag": "c:ingots/steel"}, count: 20 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 7 },
      { item: {"tag": "c:ingots/gold"}, count: 4 }
    ], {"type": "gun", "id": "tacz:lonetrail", "attachments": {"scope": "tacz:scope_contender"}})

  // m1014: было #c:ingots/iron×64 + #c:ingots/gold×12 + #c:gems/diamond×1 + #c:gems/lapis×8
  tacz(e, 'm1014', [
      { item: {"tag": "c:ingots/steel"}, count: 32 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 12 },
      { item: {"tag": "c:gems/diamond"}, count: 1 }
    ], {"type": "gun", "id": "tacz:m1014"})

  // m107: было #c:gems/diamond×18 + #c:ingots/gold×64 + #c:ingots/netherite×3 + #c:ingots/iron×320 + #c:rods/blaze×5
  tacz(e, 'm107', [
      { item: {"tag": "c:ingots/steel"}, count: 160 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 10 },
      { item: {"tag": "c:gems/diamond"}, count: 18 },
      { item: {"tag": "c:ingots/gold"}, count: 64 },
      { item: {"tag": "c:ingots/netherite"}, count: 3 },
      { item: {"tag": "c:rods/blaze"}, count: 5 },
      { item: {"item": "create:precision_mechanism"}, count: 2 }
    ], {"type": "gun", "id": "tacz:m107", "attachments": {"scope": "tacz:scope_contender"}})

  // m16a1: было #c:ingots/iron×32 + #c:gems/lapis×6 + #minecraft:logs×6
  tacz(e, 'm16a1', [
      { item: {"tag": "c:ingots/steel"}, count: 16 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "minecraft:logs"}, count: 6 }
    ], {"type": "gun", "id": "tacz:m16a1"})

  // m16a4: было #c:ingots/iron×36 + #c:gems/lapis×8 + #minecraft:logs×6
  tacz(e, 'm16a4', [
      { item: {"tag": "c:ingots/steel"}, count: 18 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "minecraft:logs"}, count: 6 }
    ], {"type": "gun", "id": "tacz:m16a4"})

  // m1911: было #c:ingots/iron×16 + #minecraft:logs×5
  tacz(e, 'm1911', [
      { item: {"tag": "c:ingots/steel"}, count: 8 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 5 }
    ], {"type": "gun", "id": "tacz:m1911"})

  // m249: было #c:gems/diamond×4 + #c:ingots/gold×16 + #c:ingots/iron×110 + #c:rods/blaze×2
  tacz(e, 'm249', [
      { item: {"tag": "c:ingots/steel"}, count: 55 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 3 },
      { item: {"tag": "c:gems/diamond"}, count: 4 },
      { item: {"tag": "c:ingots/gold"}, count: 16 },
      { item: {"tag": "c:rods/blaze"}, count: 2 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:m249"})

  // m320: было #c:ingots/gold×15 + #c:ingots/iron×50 + #c:gems/lapis×6
  tacz(e, 'm320', [
      { item: {"tag": "c:ingots/steel"}, count: 25 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 15 }
    ], {"type": "gun", "id": "tacz:m320"})

  // m4a1: было #c:ingots/iron×38 + #c:gems/lapis×6 + #minecraft:logs×8
  tacz(e, 'm4a1', [
      { item: {"tag": "c:ingots/steel"}, count: 19 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "minecraft:logs"}, count: 8 }
    ], {"type": "gun", "id": "tacz:m4a1", "attachments": {"stock": "tacz:stock_m4ss"}})

  // m700: было #c:gems/diamond×1 + #c:ingots/gold×4 + #c:ingots/iron×45
  tacz(e, 'm700', [
      { item: {"tag": "c:ingots/steel"}, count: 23 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:gems/diamond"}, count: 1 },
      { item: {"tag": "c:ingots/gold"}, count: 4 }
    ], {"type": "gun", "id": "tacz:m700", "attachments": {"scope": "tacz:scope_contender"}})

  // m870: было #c:ingots/iron×25 + #minecraft:logs×12
  tacz(e, 'm870', [
      { item: {"tag": "c:ingots/steel"}, count: 13 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 12 }
    ], {"type": "gun", "id": "tacz:m870"})

  // m95: было #c:gems/diamond×15 + #c:ingots/gold×60 + #c:ingots/netherite×3 + #c:ingots/iron×300 + #c:rods/blaze×5
  tacz(e, 'm95', [
      { item: {"tag": "c:ingots/steel"}, count: 150 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 9 },
      { item: {"tag": "c:gems/diamond"}, count: 15 },
      { item: {"tag": "c:ingots/gold"}, count: 60 },
      { item: {"tag": "c:ingots/netherite"}, count: 3 },
      { item: {"tag": "c:rods/blaze"}, count: 5 },
      { item: {"item": "create:precision_mechanism"}, count: 2 }
    ], {"type": "gun", "id": "tacz:m95", "attachments": {"scope": "tacz:scope_contender"}})

  // m9a4: было #c:ingots/iron×16
  tacz(e, 'm9a4', [
      { item: {"tag": "c:ingots/steel"}, count: 8 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 }
    ], {"type": "gun", "id": "tacz:m9a4"})

  // minigun: было #c:gems/diamond×40 + #c:ingots/gold×80 + #c:ingots/netherite×10 + #c:ingots/iron×320 + #c:rods/blaze×10
  tacz(e, 'minigun', [
      { item: {"tag": "c:ingots/steel"}, count: 160 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 10 },
      { item: {"tag": "c:gems/diamond"}, count: 40 },
      { item: {"tag": "c:ingots/gold"}, count: 80 },
      { item: {"tag": "c:ingots/netherite"}, count: 10 },
      { item: {"tag": "c:rods/blaze"}, count: 10 },
      { item: {"item": "create:precision_mechanism"}, count: 2 }
    ], {"type": "gun", "id": "tacz:minigun"})

  // mk14: было #c:ingots/gold×20 + #c:ingots/iron×84 + #c:gems/diamond×4 + #c:rods/blaze×2
  tacz(e, 'mk14', [
      { item: {"tag": "c:ingots/steel"}, count: 42 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 20 },
      { item: {"tag": "c:gems/diamond"}, count: 4 },
      { item: {"tag": "c:rods/blaze"}, count: 2 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:mk14"})

  // p320: было #c:ingots/gold×4 + #c:ingots/iron×28 + #c:gems/lapis×2
  tacz(e, 'p320', [
      { item: {"tag": "c:ingots/steel"}, count: 14 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 1 },
      { item: {"tag": "c:ingots/gold"}, count: 4 }
    ], {"type": "gun", "id": "tacz:p320"})

  // p90: было #c:ingots/gold×8 + #c:ingots/iron×72 + #c:gems/quartz×3 + #c:gems/diamond×2
  tacz(e, 'p90', [
      { item: {"tag": "c:ingots/steel"}, count: 36 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 8 },
      { item: {"tag": "c:gems/quartz"}, count: 3 },
      { item: {"tag": "c:gems/diamond"}, count: 2 }
    ], {"type": "gun", "id": "tacz:p90"})

  // qbz_191: было #c:ingots/iron×64 + #c:ingots/gold×8 + #c:gems/lapis×16 + #c:gems/quartz×8
  tacz(e, 'qbz_191', [
      { item: {"tag": "c:ingots/steel"}, count: 32 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 6 },
      { item: {"tag": "c:ingots/gold"}, count: 8 },
      { item: {"tag": "c:gems/quartz"}, count: 8 }
    ], {"type": "gun", "id": "tacz:qbz_191"})

  // qbz_95: было #c:ingots/iron×40 + #c:ingots/gold×3 + #c:gems/lapis×8 + #minecraft:logs×6
  tacz(e, 'qbz_95', [
      { item: {"tag": "c:ingots/steel"}, count: 20 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 3 },
      { item: {"tag": "minecraft:logs"}, count: 6 }
    ], {"type": "gun", "id": "tacz:qbz_95"})

  // rhino357: было #c:gems/lapis×8 + #c:ingots/gold×4 + #c:ingots/iron×32 + #minecraft:logs×5
  tacz(e, 'rhino357', [
      { item: {"tag": "c:ingots/steel"}, count: 16 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 4 },
      { item: {"tag": "minecraft:logs"}, count: 5 }
    ], {"type": "gun", "id": "tacz:rhino357"})

  // rpg7: было #c:ingots/gold×8 + #c:ingots/iron×70 + #c:gems/lapis×4 + #minecraft:logs×10
  tacz(e, 'rpg7', [
      { item: {"tag": "c:ingots/steel"}, count: 35 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 8 },
      { item: {"tag": "minecraft:logs"}, count: 10 }
    ], {"type": "gun", "id": "tacz:rpg7"})

  // rpk: было #c:ingots/iron×56 + #c:ingots/gold×8 + #c:gems/quartz×8 + #minecraft:logs×12
  tacz(e, 'rpk', [
      { item: {"tag": "c:ingots/steel"}, count: 28 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 8 },
      { item: {"tag": "c:gems/quartz"}, count: 8 },
      { item: {"tag": "minecraft:logs"}, count: 12 }
    ], {"type": "gun", "id": "tacz:rpk", "attachments": {"stock": "tacz:oem_stock_heavy"}})

  // scar_h: было #c:ingots/gold×16 + #c:ingots/iron×96 + #c:gems/diamond×2 + #c:rods/blaze×4
  tacz(e, 'scar_h', [
      { item: {"tag": "c:ingots/steel"}, count: 48 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 16 },
      { item: {"tag": "c:gems/diamond"}, count: 2 },
      { item: {"tag": "c:rods/blaze"}, count: 4 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:scar_h"})

  // scar_l: было #c:ingots/gold×6 + #c:ingots/iron×48 + #c:gems/quartz×3
  tacz(e, 'scar_l', [
      { item: {"tag": "c:ingots/steel"}, count: 24 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 6 },
      { item: {"tag": "c:gems/quartz"}, count: 3 }
    ], {"type": "gun", "id": "tacz:scar_l"})

  // sks_tactical: было #c:ingots/iron×40 + #c:gems/lapis×8 + #minecraft:logs×12
  tacz(e, 'sks_tactical', [
      { item: {"tag": "c:ingots/steel"}, count: 20 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "minecraft:logs"}, count: 12 }
    ], {"type": "gun", "id": "tacz:sks_tactical", "attachments": {"stock": "tacz:stock_m4ss"}})

  // spas_12: было #c:ingots/iron×110 + #c:ingots/gold×20 + #c:gems/diamond×2 + #c:gems/lapis×5
  tacz(e, 'spas_12', [
      { item: {"tag": "c:ingots/steel"}, count: 55 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 3 },
      { item: {"tag": "c:plates/plastic"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 20 },
      { item: {"tag": "c:gems/diamond"}, count: 2 }
    ], {"type": "gun", "id": "tacz:spas_12"})

  // spr15hb: было #c:ingots/gold×8 + #c:ingots/iron×72 + #c:gems/diamond×2 + #c:rods/blaze×5
  tacz(e, 'spr15hb', [
      { item: {"tag": "c:ingots/steel"}, count: 36 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 8 },
      { item: {"tag": "c:gems/diamond"}, count: 2 },
      { item: {"tag": "c:rods/blaze"}, count: 5 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:spr15hb"})

  // springfield1873: было #minecraft:logs×10 + #c:ingots/iron×3
  tacz(e, 'springfield1873', [
      { item: {"tag": "c:ingots/steel"}, count: 2 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 10 }
    ], {"type": "gun", "id": "tacz:springfield1873"})

  // taurus500: было #c:gems/diamond×8 + #c:ingots/gold×65 + #c:ingots/iron×85 + #c:rods/blaze×4
  tacz(e, 'taurus500', [
      { item: {"tag": "c:ingots/steel"}, count: 43 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 3 },
      { item: {"tag": "c:gems/diamond"}, count: 8 },
      { item: {"tag": "c:ingots/gold"}, count: 65 },
      { item: {"tag": "c:rods/blaze"}, count: 4 },
      { item: {"item": "create:precision_mechanism"}, count: 1 }
    ], {"type": "gun", "id": "tacz:taurus500"})

  // timeless50: было #c:gems/diamond×1 + #c:ingots/gold×6 + #c:ingots/iron×48
  tacz(e, 'timeless50', [
      { item: {"tag": "c:ingots/steel"}, count: 24 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:gems/diamond"}, count: 1 },
      { item: {"tag": "c:ingots/gold"}, count: 6 }
    ], {"type": "gun", "id": "tacz:timeless50"})

  // type_81: было #c:ingots/iron×28 + #minecraft:logs×10
  tacz(e, 'type_81', [
      { item: {"tag": "c:ingots/steel"}, count: 14 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 },
      { item: {"tag": "minecraft:logs"}, count: 10 }
    ], {"type": "gun", "id": "tacz:type_81"})

  // ump45: было #c:ingots/gold×5 + #c:ingots/iron×62 + #c:gems/quartz×3
  tacz(e, 'ump45', [
      { item: {"tag": "c:ingots/steel"}, count: 31 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:ingots/gold"}, count: 5 },
      { item: {"tag": "c:gems/quartz"}, count: 3 }
    ], {"type": "gun", "id": "tacz:ump45"})

  // uzi: было #c:ingots/iron×32
  tacz(e, 'uzi', [
      { item: {"tag": "c:ingots/steel"}, count: 16 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 1 }
    ], {"type": "gun", "id": "tacz:uzi"})

  // vector45: было #c:ingots/iron×60 + #c:gems/lapis×8 + #c:ingots/gold×12 + #c:gems/diamond×10
  tacz(e, 'vector45', [
      { item: {"tag": "c:ingots/steel"}, count: 30 },
      { item: {"item": "immersiveengineering:component_steel"}, count: 2 },
      { item: {"tag": "c:plates/plastic"}, count: 3 },
      { item: {"tag": "c:ingots/gold"}, count: 12 },
      { item: {"tag": "c:gems/diamond"}, count: 10 }
    ], {"type": "gun", "id": "tacz:vector45"})
})
