// TechnoMagic Adventures — «топливо только из нефти».
// Как устроено в jar Ad Astra 1.16.26:
//   * ракета уровня N принимает жидкости из тега ad_astra:tier_N_rocket_fuel (Rocket$RocketProperties),
//     по умолчанию ВСЕ 4 тега = #ad_astra:fuel;
//   * #ad_astra:fuel = ad_astra:fuel, #c:fuel, ad_astra:cryo_fuel, #c:diesel, #c:biodiesel
//     -> сейчас ракету можно заправить БИОДИЗЕЛЕМ (CDG/IE/MI) из семян — обход нефти;
//   * запуск: launchFuelCost=3000 мБ, «эффективное» топливо (#ad_astra:efficient_fuel = cryo_fuel) — 1000 мБ;
//   * рецепт ad_astra:refining/fuel_from_refining_oil: 5 мБ #ad_astra:oil -> 5 мБ ad_astra:fuel (Fuel Refinery);
//   * крио-топливо: cryo_freezing из льда/плотного льда/синего льда/осколка льда (ad_astra:ice_shard = 25 мБ).
// Новая цепочка: нефть (IP насос-качалка / нефтяные вышки Ad Astra / CDG) -> дистилляционная колонна IP ->
//   керосин -> Топливный завод Ad Astra -> ракетное топливо (ур. 1–3); ур. 4 — только крио-топливо из
//   осколков льда с Луны/Марса.

ServerEvents.tags('fluid', e => {
  // Ad Astra-нефть с океанских вышек теперь годится для дистилляционной колонны IP (она ест #c:crude_oil)
  e.add('c:crude_oil', ['ad_astra:oil'])

  e.removeAll('ad_astra:fuel')
  e.add('ad_astra:fuel', ['ad_astra:fuel', 'ad_astra:cryo_fuel'])

  e.removeAll('ad_astra:tier_1_rocket_fuel')
  e.removeAll('ad_astra:tier_2_rocket_fuel')
  e.removeAll('ad_astra:tier_3_rocket_fuel')
  e.removeAll('ad_astra:tier_4_rocket_fuel')
  e.add('ad_astra:tier_1_rocket_fuel', ['ad_astra:fuel', 'ad_astra:cryo_fuel'])
  e.add('ad_astra:tier_2_rocket_fuel', ['ad_astra:fuel', 'ad_astra:cryo_fuel'])
  e.add('ad_astra:tier_3_rocket_fuel', ['ad_astra:fuel', 'ad_astra:cryo_fuel'])
  e.add('ad_astra:tier_4_rocket_fuel', ['ad_astra:cryo_fuel'])

  // Марсоход: бензин/дизель из нефти или ракетное топливо
  e.removeAll('ad_astra:tier_1_rover_fuel')
  e.add('ad_astra:tier_1_rover_fuel', ['ad_astra:fuel', 'immersivepetroleum:gasoline', 'immersivepetroleum:diesel'])
})

ServerEvents.recipes(e => {
  // Топливный завод: керосин (IP) -> ракетное топливо 1:1 (60 мБ нефти дают 20 мБ керосина)
  e.remove({ id: 'ad_astra:refining/fuel_from_refining_oil' })
  e.custom({
    type: 'ad_astra:refining',
    cookingtime: 1,
    energy: 30,
    input: {
      type: 'common_storage_lib_resources:base',
      amount: 5,
      values: { tag: 'c:kerosene' }
    },
    result: { amount: 5, id: 'ad_astra:fuel' }
  }).id('kubejs:ad_astra/refining/fuel_from_kerosene')

  // Крио-топливо — только из осколков льда (планеты), без фермы обычного льда
  e.remove({ id: 'ad_astra:cryo_freezing/cryo_fuel_from_cryo_freezing_ice' })
  e.remove({ id: 'ad_astra:cryo_freezing/cryo_fuel_from_cryo_freezing_packed_ice' })
  e.remove({ id: 'ad_astra:cryo_freezing/cryo_fuel_from_cryo_freezing_blue_ice' })
  // ad_astra:cryo_freezing/cryo_fuel_from_cryo_freezing_ice_shard (1 осколок = 25 мБ) остаётся:
  // запуск ракеты 4 ур. = 1000 мБ = 40 осколков.
})
