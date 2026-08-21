import sys, os, shlex
sys.path.insert(0, "scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("c", "scripts/commontest-census.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
suite, filt = sys.argv[1], sys.argv[2]
cfg = m.parse_config(suite)
all_kt = []
for r in cfg["test_roots"]: all_kt += m.collect_kt(r)
all_kt = sorted(all_kt)
support = [p for p in all_kt if not m.has_test(p)]
targets = [p for p in all_kt if m.has_test(p)]
for d in cfg["extra_support"]: support += m.collect_kt(d)
targets = [t for t in targets if filt in t]
if cfg["whole_source_set"]:
    argv = [m.BIN, "test", "--only-file", targets[0]] + support + targets
else:
    argv = [m.BIN, "test"] + support + targets
print("HOME=%s %s" % (cfg["scratch_home"], " ".join(shlex.quote(a) for a in argv)))
