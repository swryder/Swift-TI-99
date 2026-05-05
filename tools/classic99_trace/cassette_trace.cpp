// cassette_trace.cpp
//
// Implementation of the trace logger. Self-contained — no Classic99 headers
// required. The file is opened on the first call to casTraceOpen() (we
// place that early so we don't miss boot-time motor wiggles) but the
// "trace clock" is reset to zero whenever the tape ACTUALLY begins
// playing (off→on transition gated by the user-press-PLAY logic in
// setTapeMotor). That way the cap below counts only the cycles that
// matter for cassette decode, not the seconds spent loading the WAV
// file or sitting at the BASIC prompt.

#include <stdio.h>
#include <stdarg.h>
#include <Windows.h>

#include "cassette_trace.h"

// total_cycles is the cycle counter declared in Classic99's Tiemul.cpp.
// Type/qualifiers must match the declaration there exactly:
//     volatile unsigned long total_cycles=0;
extern volatile unsigned long total_cycles;

// `casReadWord` was an attempt to expose ROMWORD-based memory access
// to Tiemul.cpp via a thin wrapper. Including cpu9900.h here pulled in
// macros that break Tiemul.cpp's compilation — reverted. We just log
// PC visits without register values; the *path* the ROM takes is the
// signal we need (i.e. does Classic99 ever take 0x1562's bail path?).
unsigned short casReadWord(unsigned short /*addr*/) {
    return 0;  // unused stub; see Tiemul.cpp PCREGS hook for why
}

static FILE*          gCasTrace      = NULL;
static unsigned long  gCasTraceStart = 0;
// Limit so the file doesn't grow forever — bumped from 30M to 180M
// (≈60s at 3MHz). The trace clock resets when the tape really starts
// playing, so this entire window is now usable for cassette decode.
static const unsigned long gCasTraceLimit = 180000000UL;

void casTraceOpen(void) {
    if (gCasTrace != NULL) return;

    // Best-effort: try c:\temp first; fall back to current directory.
    gCasTrace = fopen("c:\\temp\\cassette_trace.txt", "w");
    if (gCasTrace == NULL) {
        gCasTrace = fopen("cassette_trace.txt", "w");
    }
    if (gCasTrace == NULL) return;

    fprintf(gCasTrace, "# Classic99 v1 cassette trace\n");
    fprintf(gCasTrace, "# format: cycle event key=value...\n");
    fprintf(gCasTrace, "# events: MOTOR, CDIN, TIMERFIRE, TIMERACK,\n");
    fprintf(gCasTrace, "#         INT1ENTRY, CRUWRITE, LOAD\n");
    fprintf(gCasTrace, "# clock resets when tape actually begins playing\n");
    fflush(gCasTrace);
    gCasTraceStart = total_cycles;
}

// Reset the trace clock to zero. Call this when the tape REALLY starts
// playing (motor truly transitions on after the user-press-PLAY gate)
// so the 60-second cap covers the actual decode, not the WAV load and
// BASIC prompt time.
void casTraceResetClock(void) {
    if (gCasTrace == NULL) return;
    fprintf(gCasTrace, "----- clock reset (was at cycle %lu) -----\n",
            total_cycles - gCasTraceStart);
    fflush(gCasTrace);
    gCasTraceStart = total_cycles;
}

void casTrace(const char* fmt, ...) {
    if (gCasTrace == NULL) return;
    unsigned long t = total_cycles - gCasTraceStart;
    if (t > gCasTraceLimit) {
        // Stop logging once we hit the limit. Don't close the file — leave
        // it as a witness of where the run got to.
        return;
    }

    fprintf(gCasTrace, "%lu ", t);
    va_list args;
    va_start(args, fmt);
    vfprintf(gCasTrace, fmt, args);
    va_end(args);
    fputc('\n', gCasTrace);
    fflush(gCasTrace);  // flush every line — we want a usable file even
                        // if Classic99 crashes mid-run
}
