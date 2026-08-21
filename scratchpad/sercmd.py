import sys, shlex, importlib.util
spec = importlib.util.spec_from_file_location("c", "scripts/commontest-census.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import collections
cfg = m.parse_config("serialization")
all_kt=[]
for r in cfg["test_roots"]: all_kt += m.collect_kt(r)
all_kt=sorted(set(all_kt))
support=[p for p in all_kt if not m.has_test(p)]
targets=[p for p in all_kt if m.has_test(p)]
for d in cfg["extra_support"]: support += m.collect_kt(d)
scans=[m.decl_scan(t) for t in targets]
owner=collections.defaultdict(list)
for i,(pkg,_sc,dcl,_w) in enumerate(scans):
    for n in dcl: owner[(pkg,n)].append(i)
idx={t:i for i,t in enumerate(targets)}
sel=[t for t in targets if sys.argv[1] in t][0]
prov=[targets[b] for b in m.provider_closure(scans,owner,idx[sel])]
argv=[m.BIN,"test","--only-file",sel]+support+prov+[sel]
print("HOME=%s %s" % (cfg["scratch_home"], " ".join(shlex.quote(a) for a in argv)))
