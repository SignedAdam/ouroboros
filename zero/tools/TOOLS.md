# Toolbelt

Small executables installed to `~/.ouroboros/tools/`, on `PATH` for every agent
Ouroboros dispatches. This file is the whole spec. You should not need to read the
source or guess at a flag.

Every name is a verb and a noun, spelled out. If you can read the name you know what
it does.

| tool | what it does |
|---|---|
| `list-windows [--display N] [--assert <app>…]` | Prints every window actually on screen as `app⇥x,y WxH`; with `--assert`, exits 1 and names anything that should not be there. |
| `take-screenshot [--display N \| --region x,y,w,h \| --window id] out.png` | Saves a screenshot. Defaults to the built-in display. |
| `record-screen <seconds> [x,y,w,h] out.mp4` | Records a screen region for N seconds and writes h264 mp4. |
| `press-key <keycode> [cmd] [opt] [ctrl] [shift]` | Sends one keystroke to whatever is frontmost. |
| `type-text "<text>" [wpm]` | Types text, layout independent. |
| `open-app <app>` | Opens an app **without** bringing it to the front. |
| `focus-app <app>` | Brings an app to the front. This changes what is on screen. |
| `quit-app <app>` | Quits an app. |
| `ouro …` | The Ouroboros CLI. `ouro idea "…"` parks a thought, `ouro i "…"` files an issue. `ouro help` for the rest. |

Useful keycodes: space 49, return 36, escape 53, tab 48, delete 51, arrows 123–126.
Letters `a`–`z`: 0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6.

## Four rules that make these safe

1. **Run `list-windows --assert` immediately before you capture or drive anything.**
   State changes between the check and the action, and that is the entire failure mode.
   It costs ~40ms. Run it every time instead of reasoning about whether it is still true.
2. **Never bring an app to the front when you care what is on screen.** Use `open-app`,
   not `focus-app`. Activating an app makes macOS follow it to *its* Space, silently
   changing the screen underneath you.
3. **Drive only the app you are working on.** `press-key` and `type-text` go to whatever
   is frontmost, which may not be what you think. Assert, then type.
4. **These use Quartz, not System Events, and you should too.** `osascript … keystroke`
   leaks modifiers (a stuck Option turns the next key into a meta-chord and can switch
   apps) and never reaches some apps' global hotkeys.

## Screen geometry

Coordinates are global. The built-in display is display 1 with its origin at `0,0`;
external displays sit at negative origins. A region only means something together with
its display, so pass `--display 1` when you mean the laptop screen.

## When to reach for these

A fix to anything with a UI is not verifiable from a diff. Open the app, assert it is
the only thing on screen, screenshot it, and look. That is the difference between "it
compiles" and "the button is where it should be".
