#!/usr/bin/env python3
"""Run the field-slot claim beside the discovery ladder and report every
disagreement.

`represent/field-slots` binds a field read to a slot index at lowering. A wrong
index is a silently wrong value, so nothing may serve a claim until the two
answers are known to agree. `KLIO_SLOT_SERVE=audit` computes the claim, runs
the ladder anyway, prints a `[slot-audit] DIVERGE` line where they differ, and
serves the ladder's answer.

  KLIO_HOME=$PWD/.klio-local scripts/slot_audit_sweep.py [BIN]

Exit 0 iff no program diverges. Every condition on the claim was found here
rather than reasoned out first: a getter's backing slot, an open owner whose
subclass overrides with an accessor, a scope-qualified spelling naming an
outer class, a property with more than one cell, a delegating class, and a
body property read before its initializer ran.
"""
import concurrent.futures, glob, os, re, subprocess, sys
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN=sys.argv[1] if len(sys.argv) > 1 else ROOT + "/zig-out/bin/klio-harness"
def interactive(p):
    try:
        with open(p,errors="replace") as f:
            for _ in range(12):
                l=f.readline()
                if not l: break
                if re.search(r"//\s*corpus:\s*interactive", l): return True
    except OSError: pass
    return False
def extra(p):
    try:
        with open(p,errors="replace") as f:
            for _ in range(12):
                l=f.readline()
                if not l: break
                m=re.search(r"Run with:\s*klio run\s+(.*)",l)
                if m: return [a for a in m.group(1).split() if not a.endswith(".kt")]
    except OSError: pass
    return []
def run(f):
    env=dict(os.environ, KLIO_HOME=ROOT+"/.klio-local", KLIO_SLOT_SERVE="audit")
    try:
        p=subprocess.run([BIN,"run",f]+extra(f),cwd=ROOT,capture_output=True,timeout=180,env=env)
    except Exception: return (os.path.relpath(f,ROOT), None, [])
    out=p.stderr.decode("utf-8","replace")
    return (os.path.relpath(f,ROOT), p.returncode, [l for l in out.splitlines() if "slot-audit" in l])
files=[f for f in sorted(glob.glob(ROOT+"/examples/*.kt")) if not interactive(f)]
div=[]; bad=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    for name,rc,rows in ex.map(run, files):
        if rc != 0: bad.append((name,rc))
        div.extend((name,r) for r in rows)
print(f"programs={len(files)} nonzero={len(bad)} divergences={len(div)}")
for n,r in div[:15]: print("  ",n,r)
for n,rc in bad[:10]: print("   rc",rc,n)
sys.exit(1 if (div or bad) else 0)
