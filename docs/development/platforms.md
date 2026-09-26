# Platforms

klio builds for macOS, Linux and Windows on x86_64 and aarch64
(`-Dtarget=x86_64-windows-gnu`, `x86_64-linux-gnu`, `aarch64-linux-gnu`,
...). The interpreter reaches the operating system in one place,
`src/runtime/platform.zig`; the rest of the tree calls it rather than libc,
`std.posix` or kernel32 directly.

## What the platform layer provides

| Need | macOS and Linux | Windows |
|------|-----------------|---------|
| Monotonic clock | `clock_gettime(CLOCK_MONOTONIC)` | `QueryPerformanceCounter` |
| Wall clock | `clock_gettime(CLOCK_REALTIME)` | `GetSystemTimePreciseAsFileTime` |
| Sleep | `nanosleep` | `Sleep`, with the process timer resolution raised to 1 ms (`timeBeginPeriod`) |
| Mutex and condition variable | pthread mutex and condition | slim reader/writer lock and `CONDITION_VARIABLE` |
| Anonymous memory | `mmap` / `munmap` | `VirtualAlloc` / `VirtualFree` |
| Memory at an alignment | map `len + alignment`, trim both ends | find the aligned address in a probe reservation, release it, map exactly there |
| Unmapping part of a mapping | `munmap` of the range | decommit the range; release the reservation once none of it is committed |
| Dropping pages, keeping the range | a fresh `MAP_FIXED` anonymous mapping over them | decommit and recommit (demand-zero pages) |
| Thread stacks | pthread stacks, reserved and committed as they grow | `CreateThread` with the size as a reservation (`STACK_SIZE_PARAM_IS_A_RESERVATION`) |
| The interpreter's 256 MB stack on the calling thread | the stack pointer moved onto a mapped region | a fiber (`CreateFiberEx`), so the thread's recorded stack bounds move with it |
| The running executable's path | `/proc/self/exe`; `_NSGetExecutablePath` and `realpath` | `GetModuleFileNameW` |
| Shared libraries (the Skia shim) | `dlopen` | `LoadLibraryExW` |
| A report when the run is stopped | `SIGTERM` / `SIGINT` handlers | `SetConsoleCtrlHandler` |
| Resident memory, for the RSS watchdog | `/proc/self/statm`; mach task info | `K32GetProcessMemoryInfo` |
| Reading a bundle's own payload | `open`, `pread`, `mmap` | `CreateFileW`, `ReadFile`, `MapViewOfFile` |

`std.Thread` commits a Windows thread's whole stack up front, which would
charge each 64 MB worker stack against the system commit limit before the
thread runs; the runtime's own threads (dispatcher workers, the timer
thread, `thread { }`, the parse and check workers) start through
`platform.Thread`. The user's klio data home is `%USERPROFILE%\.klio` on
Windows (`KLIO_HOME` overrides it everywhere).

Windows waits have millisecond granularity: a sub-millisecond sleep or
timed wait lasts about a millisecond.

## What Windows does not have

These say so when asked for, and otherwise do nothing:

- The sampling profilers (`KLIO_PROF`, `KLIO_OP_PROF`, `KLIO_FN_PROF`)
  run on a `SIGPROF` interval timer.
- `KLIO_GC_LATE`'s report signals each late thread to print its own stack
  (`pthread_kill`).
- `klio sema --each` analyzes each program in a forked child; on Windows it
  analyzes them in the process and notes that a panic ends the whole run.

## Cross builds

`zig build -Dtarget=<triple>` builds the install step for another host.
It runs none of the binaries it builds: the stdlib image the install ships
under `share/klio/cache` is baked by a host klio built from the same
sources, which names it for the target binary
(`klio bake-image --stdlib-cache <dir> --for <target klio>`). An image's
name keys on its binary's size and modification time, rounded to the
100 ns NTFS keeps, and the image binds its natives by name when it loads.

`scripts/gate.sh` cross-builds `x86_64-linux-gnu` and `x86_64-windows-gnu`
into `zig-out/cross/<triple>` as a compile-only phase.

## How each platform is verified

- macOS: the full gate.
- Linux: an aarch64 Linux container builds klio natively and runs the unit
  tests, the threaded litmus and conformance fixtures, the stdlib
  commontest sweep and the example corpus; an x86_64 cross build from
  macOS compiles and links.
- Windows: compiled and linked by the gate's cross build. Nothing runs on
  Windows in the gate; the platform layer's own tests
  (`src/runtime/platform.zig`) are the first thing to run on a Windows
  host.
