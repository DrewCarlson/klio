#!/usr/bin/env python3
"""Compose UI workloads on klio and on Compose Desktop (the JVM).

Each program in programs/ runs on each runtime, the runtimes alternating
round by round. A run records its wall and CPU time and peak memory from
/usr/bin/time, its resident size and CPU every 250 ms from ps, and each
line the program prints with the time it printed it. The results go to a
JSON file that summarize.py reads; the summary is printed at the end.

    bench/compose/run.py [--klio BIN] [--rounds N] [--only NAME,...]
                         [--no-jvm | --no-klio] [--no-warm] [--env K=V ...]
                         [--out FILE]

Programs named hb_* are headless scenes (KlioComposeScene, and on the JVM
the same helper over ImageComposeScene) that print their frame timings;
wb_* open real windows, drive themselves and close. The JVM side compiles
each program with the pinned kotlinc and the Compose plugin, through
scripts/compose-oracle.py, into target/bench-compose/jvm.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PROGRAMS_DIR = os.path.join(HERE, "programs")
OUT_DIR = os.path.join(ROOT, "target", "bench-compose")
JVM_OUT = os.path.join(OUT_DIR, "jvm")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def programs():
    return sorted(f[:-3] for f in os.listdir(PROGRAMS_DIR) if f.endswith(".kt"))


def headless(name):
    return name.startswith("hb_")


def compile_jvm(oracle, name):
    """The program's classes for the JVM, compiled again only when its
    source is newer than the last build."""
    src = os.path.join(PROGRAMS_DIR, name + ".kt")
    classes = os.path.join(JVM_OUT, name)
    stamp = os.path.join(classes, ".stamp")
    if os.path.exists(stamp) and os.path.getmtime(stamp) >= os.path.getmtime(src):
        return classes
    subprocess.run(["rm", "-rf", classes], check=True)
    os.makedirs(classes)
    extra = []
    if headless(name):
        for fname, text in (("KlioComposeScene.kt", oracle.SCENE_SHIM), ("KlioGraphics.kt", oracle.GRAPHICS_SHIM)):
            p = os.path.join(classes, fname)
            with open(p, "w") as f:
                f.write(text)
            extra.append(p)
    kc = oracle.kotlinc_home()
    cp = ":".join(oracle.classpath())
    print("compiling %s for the JVM" % name, flush=True)
    r = subprocess.run([os.path.join(kc, "bin", "kotlinc"), src] + extra + [
        "-Xplugin=" + os.path.join(kc, "lib", "compose-compiler-plugin.jar"),
        "-no-stdlib", "-no-reflect", "-jvm-target", "21", "-cp", cp, "-d", classes],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("kotlinc failed for %s:\n%s" % (name, r.stderr[-3000:]))
    open(stamp, "w").close()
    return classes


def jvm_cmd(oracle, name):
    classes = compile_jvm(oracle, name)
    cmd = ["java"]
    if headless(name):
        cmd.append("-Djava.awt.headless=true")
    cmd += ["-Dskiko.data.path=" + os.path.join(oracle.ORACLE_HOME, "skiko-data"),
            "-cp", classes + ":" + ":".join(oracle.classpath()),
            name[:1].upper() + name[1:] + "Kt"]
    return cmd


def time_cmd():
    """/usr/bin/time with the flag that reports peak memory: -l on macOS,
    -v on Linux."""
    return ["/usr/bin/time", "-l" if sys.platform == "darwin" else "-v"]


def parse_time(text):
    out = {}
    m = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", text)
    if m:
        out["wall_s"], out["user_s"], out["sys_s"] = map(float, m.groups())
        for key, label in (("max_rss_mb", "maximum resident set size"), ("peak_footprint_mb", "peak memory footprint")):
            m = re.search(r"(\d+)\s+" + label, text)
            if m:
                out[key] = round(int(m.group(1)) / 1048576, 1)
        return out
    # GNU time -v
    m = re.search(r"Elapsed \(wall clock\) time.*?: (?:(\d+):)?(\d+):([\d.]+)", text)
    if m:
        h, mnt, s = m.groups()
        out["wall_s"] = int(h or 0) * 3600 + int(mnt) * 60 + float(s)
    for key, label in (("user_s", "User time \\(seconds\\)"), ("sys_s", "System time \\(seconds\\)")):
        m = re.search(label + r": ([\d.]+)", text)
        if m:
            out[key] = float(m.group(1))
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", text)
    if m:
        out["max_rss_mb"] = round(int(m.group(1)) / 1024, 1)
        out["peak_footprint_mb"] = out["max_rss_mb"]
    return out


def ps_sample(pid):
    r = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True)
    parts = r.stdout.split()
    if len(parts) < 2:
        return None
    secs = 0.0
    for piece in parts[1].replace("-", ":").split(":"):
        secs = secs * 60 + float(piece)
    return int(parts[0]), secs


def run(cmd, env, timeout):
    """One run: timestamped output lines, the time report, and an RSS/CPU
    trajectory of the program (the child of /usr/bin/time)."""
    t0 = time.monotonic()
    p = subprocess.Popen(time_cmd() + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=env, cwd=ROOT)
    lines, errs, traj = [], [], []

    def read_out():
        for line in p.stdout:
            lines.append((round(time.monotonic() - t0, 3), line.rstrip("\n")))

    def read_err():
        for line in p.stderr:
            errs.append(line)

    readers = [threading.Thread(target=read_out), threading.Thread(target=read_err)]
    for th in readers:
        th.start()
    child = None
    while p.poll() is None:
        if child is None:
            r = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True)
            if r.stdout.strip():
                child = int(r.stdout.split()[0])
        if child is not None:
            s = ps_sample(child)
            if s:
                traj.append((round(time.monotonic() - t0, 2), s[0] // 1024, s[1]))
        if time.monotonic() - t0 > timeout:
            p.kill()
            break
        time.sleep(0.25)
    for th in readers:
        th.join()
    err = "".join(errs)
    res = parse_time(err)
    res["rc"] = p.returncode
    res["lines"] = lines
    res["traj"] = traj
    res["stderr_tail"] = [l for l in err.splitlines() if not re.match(r"^\s+\d+\s+[a-z]", l)][-12:]
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--klio", default=os.path.join(ROOT, "zig-out", "bin", "klio-harness-fast"),
                    help="the klio binary (default: zig-out/bin/klio-harness-fast)")
    ap.add_argument("--home", default=os.path.join(ROOT, ".klio-local"),
                    help="KLIO_HOME for the klio runs (default: .klio-local)")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--only", help="comma-separated program names")
    ap.add_argument("--no-jvm", action="store_true")
    ap.add_argument("--no-klio", action="store_true")
    ap.add_argument("--no-warm", action="store_true",
                    help="skip the untimed first klio run that bakes each program's image")
    ap.add_argument("--env", action="append", default=[], help="K=V for the klio runs")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--out", help="results file (default: target/bench-compose/<time>.json)")
    a = ap.parse_args()

    names = programs()
    if a.only:
        wanted = a.only.split(",")
        unknown = [n for n in wanted if n not in names]
        if unknown:
            sys.exit("no program %s in %s" % (", ".join(unknown), PROGRAMS_DIR))
        names = [n for n in names if n in wanted]
    if not a.no_klio and not os.path.isfile(a.klio):
        sys.exit("%s is missing; build it with `zig build klio-harness-fast`" % a.klio)
    out = a.out or os.path.join(OUT_DIR, datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    kenv = dict(os.environ, KLIO_HOME=a.home, KLIO_RUN_STATS="1", KLIO_LOCALE="en-US", KLIO_SYSTEM_THEME="light")
    for kv in a.env:
        k, v = kv.split("=", 1)
        kenv[k] = v
    oracle = None if a.no_jvm else load("compose_oracle", os.path.join(ROOT, "scripts", "compose-oracle.py"))

    results = []
    for name in names:
        src = os.path.join(PROGRAMS_DIR, name + ".kt")
        arms = []
        if not a.no_klio:
            arms.append(("klio", [a.klio, "run", src], kenv))
            if not a.no_warm:
                # A binary's first run of a program bakes its image; the
                # timed runs are the ones a user repeats.
                print(name, "klio warm-up", flush=True)
                subprocess.run([a.klio, "run", src], env=kenv, cwd=ROOT,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=a.timeout)
        if not a.no_jvm:
            arms.append(("jvm", jvm_cmd(oracle, name), dict(os.environ)))
        for rnd in range(a.rounds):
            for arm, cmd, env in (arms if rnd % 2 == 0 else list(reversed(arms))):
                r = run(cmd, env, a.timeout)
                r.update(program=name, arm=arm, round=rnd)
                results.append(r)
                brief = {k: r.get(k) for k in ("wall_s", "max_rss_mb", "peak_footprint_mb", "rc")}
                print(name, arm, rnd, brief, [l for _, l in r["lines"]][-1:], flush=True)
                with open(out, "w") as f:
                    json.dump(results, f, indent=1)

    print("\nresults:", out)
    load("summarize", os.path.join(HERE, "summarize.py")).report(results)


if __name__ == "__main__":
    main()
