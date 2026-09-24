# The JIT, archived

The arm64 (and x86-64) function and loop JIT that compiled the old
interpreter's instructions to native code: `src/jit/` holds the emitters
(`jit.zig`, `arm64.zig`) and `src/ir/jit_loop.zig` with `src/ir/jit_loop/`
the compiler, laid out as they were under the repository root. Bodies
lowered from sema never reached it.

It last compiled at commit bcf0a9f7. Nothing builds it: it is not a module
in `build.zig`, no source imports it, and no script reads these files. The
design record is `docs/design/JIT-DESIGN.md`.
