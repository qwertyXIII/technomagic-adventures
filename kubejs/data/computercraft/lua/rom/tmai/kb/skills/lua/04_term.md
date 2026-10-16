TERM (экран компьютера; у монитора те же методы)
- write(text), clear(), clearLine(), setCursorPos(x, y) (от 1), getCursorPos(), getSize() → w, h (компьютер 51×19, карманный 26×20, черепашка 39×13).
- setTextColor(c), setBackgroundColor(c), getTextColor(), isColor() (true у продвинутых), scroll(n), setCursorBlink(b).
- blit(text, fg, bg) — строка с цветами по символам: fg/bg — строки той же длины из hex-цифр ("0".."f"), colors.toBlit(colors.red) → "e".
- term.redirect(mon) — весь вывод (print, write) на монитор; вернуть: term.redirect(term.native()). term.current() — текущий.
- Только латиница и псевдографика CC (символы 128–159 — блоки 2×3). Кириллица выводится как «?».

COLORS (colours — то же)
white, orange, magenta, lightBlue, yellow, lime, pink, gray, lightGray, cyan, purple, blue, brown, green, red, black. На обычном (не продвинутом) мониторе/компьютере — только white/black/gray/lightGray.
colors.combine(a, b), colors.subtract(c, a), colors.test(c, a) — для связки цветов (bundled-кабели). colors.packRGB(r, g, b); term.setPaletteColor(colors.red, 0xFF0000).

МОНИТОР (тип "monitor")
- local mon = peripheral.find("monitor") or error("No monitor", 0)
- mon.setTextScale(s) — 0.5…5 шагом 0.5; меньше масштаб — больше символов. Размер в символах зависит от числа блоков (до 8×6) и масштаба — всегда бери mon.getSize() ПОСЛЕ setTextScale и подстраивай вывод под ширину.
- Клик по продвинутому монитору → событие monitor_touch(сторона_или_имя, x, y). Обычный монитор кликов не шлёт.
- Мерцание при частой перерисовке: рисуй в window и показывай разом (ниже), не clear() каждые 0.1 с; 1–2 обновления в секунду достаточно.

WINDOW (буфер / окно)
```lua
local mon = peripheral.find("monitor") or error("No monitor", 0)
mon.setTextScale(1)
local w, h = mon.getSize()
local win = window.create(mon, 1, 1, w, h, false)  -- невидимый буфер во весь монитор
local function bar(y, label, frac, col)           -- полоса заполнения 0..1
  frac = math.max(0, math.min(1, frac or 0))
  win.setCursorPos(1, y); win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  win.write(label)
  local width = w - 2
  local fill = math.floor(width * frac + 0.5)
  win.setCursorPos(2, y + 1)
  win.setBackgroundColor(col); win.write(string.rep(" ", fill))
  win.setBackgroundColor(colors.gray); win.write(string.rep(" ", width - fill))
  win.setBackgroundColor(colors.black)
end
local function draw(frac)
  win.setVisible(false)                  -- рисуем в скрытом буфере
  win.setBackgroundColor(colors.black); win.clear()
  bar(1, ("Energy %5.1f%%"):format(frac * 100), frac, frac < 0.2 and colors.red or colors.lime)
  win.setVisible(true)                   -- показываем разом, без мерцания
end
```
- window.create(parent, x, y, w, h[, visible]); у окна методы term плюс setVisible, redraw, reposition(x, y, w, h), getPosition.

КНОПКИ НА МОНИТОРЕ
Храни прямоугольники кнопок {x1, y1, x2, y2, action}; в monitor_touch ищи попадание. Подпись — латиницей.

PAINTUTILS
paintutils.drawPixel(x, y, c), drawLine(x1, y1, x2, y2, c), drawBox(…), drawFilledBox(x1, y1, x2, y2, c) — рисуют в текущий term (сначала term.redirect(mon), потом верни term.native()).

ТЕКСТ
- require("cc.strings").wrap(text, width) → строки; ensure_width(s, n) — обрезать/дополнить.
- Числа: string.format("%.1f", x); большие — ("%.2f MFE"):format(x / 1e6).
- read() ждёт ввода с клавиатуры — в автоматике не использовать (только если программа интерактивная и игрок у компьютера).
