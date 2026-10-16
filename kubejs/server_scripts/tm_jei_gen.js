// СГЕНЕРИРОВАНО tools/gen/build.py из tools/gen/lore.py — не править вручную.

// Сюжетные предметы не показываются в JEI (анти-спойлер). Рецепты финальных предметов описаны в квестах.
RecipeViewerEvents.removeEntriesCompletely('item', event => {
  event.remove([
    'kubejs:capsule_log', 'kubejs:note_m_1', 'kubejs:crew_tag', 'kubejs:cargo_stencil',
    'kubejs:song_lullaby', 'kubejs:untitled_book', 'kubejs:raider_order', 'kubejs:copper_plaque',
    'kubejs:shift_list', 'kubejs:note_m_2', 'kubejs:gold_tally', 'kubejs:scorched_journal',
    'kubejs:operator_log', 'kubejs:ark_label', 'kubejs:deep_song', 'kubejs:zealot_sermon',
    'kubejs:warden_plate', 'kubejs:oldest_tablet', 'kubejs:note_m_margin', 'kubejs:note_m_3',
    'kubejs:chronicle_1', 'kubejs:aurellan_last_page', 'kubejs:sky_sample', 'kubejs:glider_log',
    'kubejs:lethe_sample', 'kubejs:note_m_4', 'kubejs:echo_chronicle', 'kubejs:diary_ko',
    'kubejs:note_m_5', 'kubejs:watch_log', 'kubejs:pilgrim_guide', 'kubejs:station_log',
    'kubejs:choir_message', 'kubejs:bridge_shard', 'kubejs:surgeon_report', 'kubejs:note_m_6',
    'kubejs:belsky_log_1', 'kubejs:belsky_log_2', 'kubejs:exodus_manifesto', 'kubejs:cradle_lab_log',
    'kubejs:solar_session', 'kubejs:glacio_letter', 'kubejs:growth_record', 'kubejs:stack_zero',
    'kubejs:locman_core', 'kubejs:note_m_7', 'kubejs:lethe_two', 'kubejs:lethe_two_primed',
    'kubejs:mnemosyne_core', 'kubejs:infinite_resonator', 'kubejs:epilogue_token_a', 'kubejs:epilogue_token_b',
    'kubejs:epilogue_token_c',
  ])
})
