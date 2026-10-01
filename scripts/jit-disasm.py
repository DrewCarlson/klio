#!/usr/bin/env python3
"""Disassemble the code KLIO_JIT_DUMP_CODE printed, each op's start marked.

    KLIO_JIT=1 KLIO_JIT_DUMP=<id> KLIO_JIT_DUMP_CODE=1 klio run app.kt 2> dump.log
    scripts/jit-disasm.py dump.log

The id is the `#` KLIO_JIT_LOG prints. AArch64 code needs an assembler and
objdump that take arm64 (`as -arch arm64` on macOS, or an aarch64 binutils);
x86-64 code needs `as` and `objdump` for x86-64. `--arch x86_64` picks it.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", help="stderr of the run")
    ap.add_argument("--arch", default="arm64", choices=["arm64", "x86_64"])
    args = ap.parse_args()

    code = bytearray()
    op_at: dict[int, list[int]] = {}
    with open(args.log, errors="replace") as f:
        for line in f:
            m = re.search(r"\[jit-code\] ([0-9a-f]+) ([0-9a-f]+)", line)
            if m:
                off = int(m.group(1), 16)
                if off == 0:
                    code.clear()
                    op_at.clear()
                code[off:] = bytes.fromhex(m.group(2))
                continue
            m = re.search(r"\[jit-op\] (\d+) ([0-9a-f]+)", line)
            if m:
                op_at.setdefault(int(m.group(2), 16), []).append(int(m.group(1)))
    if not code:
        print("no [jit-code] lines in the log", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "code.s")
        obj = os.path.join(d, "code.o")
        with open(src, "w") as s:
            s.write(".text\n")
            if args.arch == "arm64":
                for i in range(0, len(code), 4):
                    s.write(".inst 0x%08x\n" % int.from_bytes(code[i:i + 4], "little"))
            else:
                for i in range(0, len(code), 16):
                    s.write(".byte " + ",".join("0x%02x" % b for b in code[i:i + 16]) + "\n")
        as_cmd = ["as", "-arch", "arm64"] if (args.arch == "arm64" and sys.platform == "darwin") else ["as"]
        subprocess.run(as_cmd + [src, "-o", obj], check=True)
        out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", obj], check=True, capture_output=True, text=True).stdout

    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):", line)
        if m and int(m.group(1), 16) in op_at:
            pcs = ", ".join(str(p) for p in op_at[int(m.group(1), 16)])
            print(f"; op {pcs}")
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
