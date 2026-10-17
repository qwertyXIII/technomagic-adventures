// TechnoMagic Adventures — развести совпадающие клавиши модов (клиент).
// Колесо эмоций Emotecraft по умолчанию на B, как и «открыть рюкзак» Sophisticated Backpacks.
// При входе в мир: если у колеса эмоций та же клавиша, что у другого действия, переносим его на первую
// свободную из списка и сохраняем настройки. Свою раскладку игрок может задать в «Управлении» —
// скрипт трогает клавишу, только пока она с чем-то совпадает.
const TM_KEY_MOVES = [
  { name: 'key.emotecraft.fastchoose', candidates: ['key.keyboard.j', 'key.keyboard.y', 'key.keyboard.h', 'key.keyboard.n', 'key.keyboard.k'] }
]

ClientEvents.loggedIn(event => {
  try {
    const InputConstants = Java.loadClass('com.mojang.blaze3d.platform.InputConstants')
    const KeyMapping = Java.loadClass('net.minecraft.client.KeyMapping')
    const options = Client.options
    const all = options.keyMappings
    let changed = false
    TM_KEY_MOVES.forEach(move => {
      let target = null
      for (let i = 0; i < all.length; i++) if (String(all[i].getName()) === move.name) target = all[i]
      if (!target || target.isUnbound()) return
      const cur = String(target.saveString())
      const clash = (key) => {
        for (let j = 0; j < all.length; j++) {
          if (all[j] !== target && String(all[j].saveString()) === key) return true
        }
        return false
      }
      if (!clash(cur)) return
      for (let c = 0; c < move.candidates.length; c++) {
        if (!clash(move.candidates[c])) {
          target.setKey(InputConstants.getKey(move.candidates[c]))
          console.info(`[TM] keybind ${move.name}: ${cur} -> ${move.candidates[c]}`)
          changed = true
          return
        }
      }
    })
    if (changed) {
      KeyMapping.resetMapping()
      options.save()
    }
  } catch (err) {
    console.warn('[TM] keybinds: ' + err)
  }
})
