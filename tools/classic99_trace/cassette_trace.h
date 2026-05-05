// cassette_trace.h
//
// Lightweight trace logger added to Classic99 v1 to capture the cassette
// decode path's CDIN reads, timer fires/acks, and level-1 ISR entries so
// we can diff against Swift99a's equivalent log and find where the two
// emulators diverge during cassette read.
//
// Output: c:\temp\cassette_trace.txt (line-oriented, parseable).
//
// Usage from C/C++ in Classic99: just call casTrace(...) anywhere.
// Trace becomes active at the first MOTOR on call and auto-cuts off after
// ~10 seconds of CPU time so the file stays small.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void casTraceOpen(void);
void casTraceResetClock(void);
void casTrace(const char* fmt, ...);

#ifdef __cplusplus
}
#endif
