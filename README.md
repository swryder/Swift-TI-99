# Swift 99/a

A native macOS emulator for the **Texas Instruments TI-99/4A** home computer (1981), written from scratch in Swift and SwiftUI.

<p align="center">
  <img src="For%20ReadMe/Swif99a%20Screen.png" alt="Swift 99/a in Monitor Mode" width="600"/>
</p>

---

## Why this exists

Swift 99/a started as a thought experiment for a LinkedIn article I wrote about how *real* projects scale in the AI era:

> **[Complexity is Conserved: How to do Big Things in the AI Era](https://www.linkedin.com/pulse/complexity-conserved-how-do-big-things-ai-era-scott-ryder-zyybc/)**

The premise is simple: AI tooling shifts *where* the complexity lives, but it does not erase it. To test that idea on a non-trivial problem, I picked something I could measure honestly — emulating a 1981 home computer at the chip level. CPU, video processor, sound generator, speech synthesizer, keyboard matrix, disk DSR, cartridge banking. None of it is mockable. Either the ROM boots, or it doesn't.

This repository is the result. It's a working, useful TI-99/4A emulator, and it's also the working artifact behind the article. If you're curious what "AI-assisted" looks like on a project that has to interface with 45-year-old hardware quirks, the source is here for you to read.

---

## Features

### Hardware emulation
- **TMS9900 CPU** — full instruction set, workspace-pointer architecture, context switching, status-register lookup tables for hot-path performance
- **TMS9918A VDP** — Graphics I/II, Text 40-col, Multicolor, and Bitmap modes; 32 hardware sprites with collision detection; NTSC timing
- **SN76489 PSG** — three tone channels + noise, logarithmic volume, fractional clock accumulator for accurate pitch
- **TMS5220 Speech Synthesizer** — optional, with bundled `spchrom.bin`
- **TMS9901 I/O controller** — CRU bit-addressable interface for keyboard, joystick, and DSR
- **Memory map** — 64 KB CPU space, GROM, scratchpad, 32 KB expansion RAM, cartridge ROM/banked

### Cartridges
- Raw ROM dumps (`.bin`, `.rom`) using the standard `C/D/G` filename convention
- **TiCart** (`.ticart`) — Win994a-compatible, LZW-compressed
- Multiple banking styles: standard 8 KB, GROM-only, banked (378 / inverted 379), MBX (fixed/banked/RAM)

### Disks (DSK1–DSK3)
- V9T9 disk images (`.dsk`, `.tidisk`)
- Full DSR with PAB protocol: open, close, read, write, delete, status, directory listing
- Variable and fixed-length records, FDR parsing, cluster management
- **Read and write** — your saves stick

### Input
- 8×8 keyboard matrix scanning via CRU
- Sensible Mac key remaps: Backspace → `FCTN+S`, Esc → `FCTN+4` (CLEAR/BREAK), arrows → cursor, plus full symbol remapping
- Joystick emulation via arrow keys or game controller
- **Keyboard menu** with discoverable `FCTN`+number shortcuts (DEL, INS, ERASE, CLEAR, BEGIN, PROC'D, AID, REDO, BACK, QUIT)
- **Clipboard paste** — paste text from macOS straight into the TI as keyboard events

### Display
- **Monitor Mode** — chromeless TI-99/4 monitor bezel, draggable from anywhere, transparent background for desktop integration
- **Window Mode** — standard SwiftUI window with full VDP output including border
- Real-time **FPS** and **MHz** overlays
- Toggle between authentic 3 MHz speed and uncapped maximum

### Memory Map visualizer

<p align="center">
  <img src="For%20ReadMe/Window%20and%20Memory%20View.jpg" alt="Swift 99/a window with live memory heatmap" width="800"/>
</p>

A live 256×256 heatmap of the entire 64 KB CPU address space, GPU-rendered with Metal:
- Blue for reads, red for writes, purple for both
- White-hot decay tracks recent activity
- Rainbow HSV or green-phosphor monochrome palettes
- Useful for understanding what your code is *actually* doing on the hardware

---

## Requirements

- **macOS 14.6** (Sonoma) or later
- **Xcode 15+** to build from source
- Apple Silicon or Intel Mac

No third-party dependencies. Pure Swift, SwiftUI, AppKit, and Metal.

---

## Building & running

```bash
git clone <your-fork-url>
cd "Swift99a Source"
open Swift99a.xcodeproj
```

Hit **⌘R** in Xcode. The TI-99/4A console ROM and GROM are bundled in source (`TI994AROMData.swift`, `TI994AGROMData.swift`), so the emulator boots to the familiar `READY-PRESS ANY KEY TO BEGIN` master title screen on first launch with no extra setup.

---

## Bring your own software

The repository ships **only** with what's needed to boot the bare console:

- TI-99/4A console ROM and GROM (in source, as `TI994AROMData.swift` / `TI994AGROMData.swift`)
- TMS5220 speech ROM (`spchrom.bin`)
- A small demo cartridge for sanity-checking (`DemoCartGROMData.swift`)

**No third-party cartridges or disk images are included.** You'll need to supply your own:

- **Cartridges** — drop `.bin`, `.rom`, or `.ticart` files into the app and load them from the menu. Solid sources include the [FinalGROM 99](http://endlos99.github.io/finalgrom99/) project and [WHTech](http://ftp.whtech.com/).
- **Disk images** — V9T9 `.dsk` / `.tidisk` files load into DSK1–DSK3.

If you have original cartridges and want to dump them, that's also a perfectly fine path.

---

## Project layout

```
Swift99a/
├── Emulator/
│   ├── CPU/            TMS9900 + opcodes
│   ├── VDP/            TMS9918 + rendering
│   ├── Sound/          SN76489
│   ├── Speech/         TMS5220 + coefficients + spchrom.bin
│   ├── Memory/         ROM, GROM, scratchpad, expansion RAM
│   ├── Cartridge/      Loader, banking, TiCart format
│   ├── Disk/           DSR, V9T9 image, PAB protocol
│   ├── Keyboard/       TIKeyboard matrix + remaps
│   ├── Core/           EmulatorSystem, AudioEngine, DisplayBuffer, TMS9901
│   ├── Systems/        TI994A — top-level wiring
│   └── Data/           Bundled console ROM/GROM and demo cart
├── ContentView.swift
└── Swift99aApp.swift
```

Each chip has its own file with no cross-cutting abstractions. If you want to understand how the VDP draws sprites, you read `TMS9918+Rendering.swift`. That's it.

---

## Roadmap

A short, honest list of things that are not yet done:

- 32 KB Memory Expansion is implemented; PEB peripheral cards beyond disk and speech are not
- No save-state / snapshot support
- Cassette tape (CS1/CS2) is unimplemented
- A few obscure cartridge banking schemes are not yet covered

Issues and PRs welcome.

---

## License

**BSD 2-Clause.** Do whatever you like with the code — fork it, ship it, learn from it, build on it.

If you do use it, I'd genuinely appreciate a link back to the article that motivated the project:

> [Complexity is Conserved: How to do Big Things in the AI Era](https://www.linkedin.com/pulse/complexity-conserved-how-do-big-things-ai-era-scott-ryder-zyybc/)

That's a request, not a license condition. The full license text is in [`LICENSE`](LICENSE).

---

## Acknowledgments

- Texas Instruments, for the original TI-99/4A — a beautiful, weird machine
- The TI-99/4A community at [AtariAge](https://atariage.com/forums/forum/119-ti-994a-development/), [WHTech](http://ftp.whtech.com/), and the [FinalGROM 99](http://endlos99.github.io/finalgrom99/) project, whose documentation and dumps made every part of this possible
- Thierry Nouspikel's [TI-99/4A Tech Pages](http://www.unige.ch/medecine/nouspikel/ti99/) — still the definitive hardware reference 30+ years later
- Win994a, Classic99, and js99er — prior-art emulators whose behavior I cross-checked against more times than I can count

— *Scott Ryder*
