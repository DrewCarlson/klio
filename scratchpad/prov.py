import os, re, sys, collections, importlib.util
spec = importlib.util.spec_from_file_location('c', 'scripts/commontest-census.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

MODS = r"(?:public|internal|private|protected|expect|actual|open|abstract|sealed|final|data|value|enum|annotation|inline|suspend|external|const|lateinit|operator|infix|tailrec)"
TOP = re.compile(r"^(?:" + MODS + r"\s+)*(fun|val|var|class|interface|object|typealias)\s+(.*)$", re.M)
def top_names(src):
    out=set()
    for kw, tail in TOP.findall(src):
        t=tail.strip()
        if t.startswith("<"):
            d=0
            for i,c in enumerate(t):
                if c=="<": d+=1
                elif c==">":
                    d-=1
                    if d==0: t=t[i+1:].strip(); break
        mm=re.match(r"([\w.<>?, \[\]]*?)([A-Za-z_]\w*)\s*[({:=<]", t) if kw=="fun" else re.match(r"([A-Za-z_]\w*)", t)
        if not mm: 
            mm=re.match(r"([A-Za-z_]\w*)", t)
            if not mm: continue
            out.add(mm.group(1)); continue
        out.add(mm.group(2) if kw=="fun" else mm.group(1))
    return out

suite=sys.argv[1]
cfg=m.parse_config(suite)
all_kt=[]
for r in cfg["test_roots"]: all_kt+=m.collect_kt(r)
targets=[p for p in sorted(set(all_kt)) if m.has_test(p)]
texts={t:open(t,errors="replace").read() for t in targets}
pkg={t:(re.search(r"^package\s+(\S+)",texts[t],re.M).group(1) if re.search(r"^package\s+(\S+)",texts[t],re.M) else "") for t in targets}
decl={t:top_names(texts[t]) for t in targets}
words={t:set(re.findall(r"[A-Za-z_]\w*",texts[t])) for t in targets}
owner=collections.defaultdict(list)
for t in targets:
    for n in decl[t]: owner[(pkg[t],n)].append(t)
tot=0
for t in targets:
    need=set()
    for n in words[t]-decl[t]:
        for o in owner.get((pkg[t],n),[]):
            if o!=t: need.add(o)
    if need:
        tot+=len(need)
        print(os.path.basename(t), "->", sorted(os.path.basename(x) for x in need))
print("total extra file-inclusions:", tot, "over", len(targets), "targets")
