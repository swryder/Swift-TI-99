# Classic99 v1 cassette trace instrumentation

Adds a small trace logger to Classic99 v1 so we can compare its successful
cassette decode against Swift99a's failure on the same input.
The trace captures CDIN reads, timer fires/acks, and level-1 ISR entries —
all keyed to the CPU cycle counter so the two emulators' logs can be
diffed directly.

## What you need

On your **Mac** (already done — files are in this directory):
- `cassette_trace.h`
- `cassette_trace.cpp`
- `tape.cpp`        (modified copy of `classic99-main/console/tape.cpp`)
- `Tiemul.cpp`      (modified copy of `classic99-main/console/Tiemul.cpp`)

On your **Windows PC**, you'll need:
- Visual Studio Community 2019 or later, with the **Desktop development with C++** workload installed (you said you're already setting this up)
- The Classic99 source (same `classic99-main.zip` you already used to build Classic99 successfully)
- `CATALOG.WAV` (the same file that Classic99 already decodes correctly)

## Step 1 — Move the files to the PC

Copy these four files from this directory to the Windows PC:

```
cassette_trace.h
cassette_trace.cpp
tape.cpp                   (modified)
Tiemul.cpp                 (modified)
```

Easiest path: zip the `tools/classic99_trace` directory and email/AirDrop/USB it to the PC.

## Step 2 — Set up the source tree on the PC

1. Unzip a fresh copy of `classic99-main` somewhere convenient (e.g. `C:\Dev\classic99-main`).
2. Copy the two modified files **on top of the originals**:
   - `tape.cpp`   →  `C:\Dev\classic99-main\console\tape.cpp`         (overwrites)
   - `Tiemul.cpp` →  `C:\Dev\classic99-main\console\Tiemul.cpp`        (overwrites)
3. Copy the two new files **into the same `console\` directory**:
   - `cassette_trace.h`   →  `C:\Dev\classic99-main\console\cassette_trace.h`
   - `cassette_trace.cpp` →  `C:\Dev\classic99-main\console\cassette_trace.cpp`

## Step 3 — Add the new file to the VS project

1. Open `C:\Dev\classic99-main\classic99.sln` in Visual Studio.
2. In **Solution Explorer**, find the **classic99** project.
3. Right-click on a folder inside the project (the `console` folder if there is one, or just on the project name) →  **Add → Existing Item…** →  navigate to `console\cassette_trace.cpp` →  **Add**.
4. Repeat for `cassette_trace.h` (or skip — VS will pick up the header automatically since it's in the include path).

> If you can't tell which "folder" the existing console files live in, just look at where `tape.cpp` is in Solution Explorer and add `cassette_trace.cpp` next to it. The folder grouping in Solution Explorer is purely cosmetic.

## Step 4 — Build

1. Set the build configuration to **Debug | x64** (or whichever you used last time — must match).
2. **Build → Build Solution** (or `Ctrl+Shift+B`).
3. If you get a linker error about `casTrace` being undefined, it means `cassette_trace.cpp` isn't being compiled — go back to step 3 and make sure it shows up in Solution Explorer with no excluded-from-build flags.

## Step 5 — Prepare the trace output directory

The trace logger writes to `c:\temp\cassette_trace.txt`. Create that directory once:

```cmd
mkdir c:\temp
```

(If `c:\temp` is a problem, the trace falls back to writing `cassette_trace.txt` in whatever the CWD is when Classic99 launches.)

## Step 6 — Run and capture

1. Launch the patched Classic99 from VS (`F5`).
2. **Load → Cassette → Wave Audio File** (whatever the menu is) → pick `CATALOG.WAV`.
3. At the BASIC prompt, type `OLD CS1` and press **Enter**.
4. When prompted to "rewind cassette tape and press ENTER", press **Enter**.
5. When prompted to "press cassette PLAY and press ENTER", press **Enter**.
6. **As soon as you see "READING"**, wait ~3-5 seconds, then **stop the run** (`Shift+F5` or close Classic99).
   - The trace logger auto-cuts off at ~10 seconds of CPU time, so even if you let it run to completion the file stays bounded.
   - We only need the first few seconds of leader-detection data to find where the two emulators diverge.

## Step 7 — Send the trace back

The output file is `c:\temp\cassette_trace.txt` (or `cassette_trace.txt` next to the executable if the fallback triggered).

Zip it up and email/AirDrop/USB it back to the Mac, drop it somewhere I can read it (`~/Downloads` is fine), and tell me where it is.

## Trace format

Plain text, one event per line, space-separated:

```
<cycles> <event> [<key=value> ...]
```

Where `<cycles>` is total CPU cycles since the first MOTOR call (so the start of the trace is `0`). Events:

| Event       | Fields                                            | Meaning                                              |
|-------------|---------------------------------------------------|------------------------------------------------------|
| `MOTOR`     | `req= prevOn= state= pos= size=`                  | CRU motor write — `req=1` motor-on, `req=0` motor-off |
| `LOAD`      | `avg= scale= size= first=...`                     | WAV processing complete, with first 16 PCM samples   |
| `CDIN`      | `pos= sample= bit= motor=`                        | Every TB 27 read; `bit` = post-threshold value       |
| `TIMERFIRE` | `start=`                                          | Timer reached 0 and `timer9901IntReq` was set        |
| `TIMERACK`  | `op=SBO|SBZ had=`                                 | CRU bit 3 write cleared the latch                    |
| `INT1ENTRY` | `pc= wp= st= src=V|T|VT`                          | Level-1 interrupt taken; `src` = VDP and/or timer    |
| `CRUWRITE`  | `op=SBO bit= clockmode=1 starttimer=`             | Timer-load bit write while in clock mode             |

## What I'll do with it

On my end, I'll add equivalent logging to Swift99a (same event names, same format), capture a parallel trace running the **same** CATALOG.WAV through the same OLD CS1 sequence, and `diff` the two side-by-side. The first cycle where the two diverge is where the bug lives.

Most likely we'll find one of:
- A `TIMERFIRE` rate mismatch (I'm firing too fast/slow)
- A `CDIN` value mismatch at the same `pos` (my WAV processing differs from Classic99's even though the code looks identical)
- A different `src=` on `INT1ENTRY` events (my interrupt routing differs)
- A different `INT1ENTRY pc=` (my CPU's instruction stream is taking a different branch)

## Reverting

To go back to a clean Classic99 v1: delete `cassette_trace.h/.cpp` from `console\`, restore the original `tape.cpp` and `Tiemul.cpp` from a fresh `classic99-main.zip`, remove `cassette_trace.cpp` from the VS project, rebuild.
