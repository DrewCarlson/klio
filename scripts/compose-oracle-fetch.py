#!/usr/bin/env python3
"""Resolve a transitive JVM runtime classpath from Maven repositories.

Usage:
  fetch.py [--jars DIR] [--exclude group:module ...] [coordinate ...]

A coordinate is group:module:version, or group:module:=group2:module2 to take
whatever version the resolution selects for group2:module2 (used to pin the
skiko native runtime to the skiko the graph picked). With no coordinates the
Compose Multiplatform Desktop 1.12.0 root set is used.

Resolution follows Gradle's rules closely enough for Kotlin Multiplatform
libraries:
  * Gradle module metadata (.module) is read when published, else the POM.
  * The variant is the JVM runtime one: category=library, usage=java-runtime
    (java-api as a fallback), platform.type=jvm, jvm.environment=standard-jvm,
    the highest jvm.version <= the running JDK.
  * available-at redirects (a KMP root such as compose ui -> ui-desktop) become
    an edge to the redirect target.
  * Dependencies and dependencyConstraints both vote; the highest version of a
    module wins. Platform (BOM) dependencies contribute constraints only.
  * POM compile and runtime scopes are followed; test/provided/system and
    optional dependencies are not. Parent POMs, properties and imported BOMs
    feed dependencyManagement.
Repositories are tried in order: Maven Central, then Google Maven.

Jars land in DIR/<group>/ (default DIR: target/parity-cache/compose-desktop-1.12.0/jars);
DIR/classpath.txt lists them in resolution order. Metadata is cached beside it
(the cache/ directory of the same parent). scripts/compose-oracle.py drives this.
"""

import argparse
import functools
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import OrderedDict, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORACLE_HOME = os.environ.get(
    "COMPOSE_ORACLE_HOME", os.path.join(ROOT, "target", "parity-cache", "compose-desktop-1.12.0"))
REPOS = [
    "https://repo1.maven.org/maven2",
    "https://maven.google.com",
]
JDK_VERSION = 21

DEFAULT_ROOTS = [
    # Match the compiler: a Gradle build on Kotlin 2.4.20 puts this stdlib on
    # the classpath, and it outranks the 2.2.x the Compose modules request.
    "org.jetbrains.kotlin:kotlin-stdlib:2.4.20",
    "org.jetbrains.compose.ui:ui-desktop:1.12.0",
    "org.jetbrains.compose.foundation:foundation-desktop:1.12.0",
    # Compose Multiplatform 1.12.0 pairs with material3 1.12.0-alpha03
    # (CHANGELOG "Components" table for 1.12.0).
    "org.jetbrains.compose.material3:material3-desktop:1.12.0-alpha03",
    "org.jetbrains.compose.ui:ui-test-desktop:1.12.0",
    "org.jetbrains.skiko:skiko-awt-runtime-macos-arm64:=org.jetbrains.skiko:skiko-awt",
    "org.jetbrains.kotlinx:kotlinx-coroutines-swing:=org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm",
    # File reading for the examples, at the version klio's kotlinx-io pack vendors.
    "org.jetbrains.kotlinx:kotlinx-io-core:0.9.1",
]


def log(*a):
    print(*a, file=sys.stderr)


# ---------------------------------------------------------------- versions

_QUAL_ORDER = {"dev": -1, "rc": 1, "snapshot": 2, "final": 3, "ga": 4, "release": 5, "sp": 6}


def _vparts(v):
    parts = []
    for chunk in re.split(r"[.\-_+]", v):
        for p in re.findall(r"\d+|[A-Za-z]+", chunk):
            parts.append(int(p) if p.isdigit() else p.lower())
    return parts


def _part_key(p):
    # numeric > any string; among strings: dev < other < rc < snapshot < final < ga < release < sp
    if isinstance(p, int):
        return (2, p, "")
    return (1, _QUAL_ORDER.get(p, 0), p)


def vcmp(a, b):
    pa, pb = _vparts(a), _vparts(b)
    for x, y in zip(pa, pb):
        kx, ky = _part_key(x), _part_key(y)
        if kx != ky:
            return -1 if kx < ky else 1
    if len(pa) == len(pb):
        return 0
    # an extra numeric part is higher, an extra qualifier is lower
    longer, sign = (pa, 1) if len(pa) > len(pb) else (pb, -1)
    extra = longer[min(len(pa), len(pb))]
    return sign if isinstance(extra, int) else -sign


def vmax(versions):
    best = None
    for v in versions:
        if v is None:
            continue
        if best is None or vcmp(v, best) > 0:
            best = v
    return best


def pick_range(v):
    """Maven range '[a,b)' or '[a]': take the lower bound (or the single value)."""
    if v and v[0] in "[(":
        inner = v.strip("[]()")
        lo = inner.split(",")[0].strip()
        return lo or None
    return v


# ---------------------------------------------------------------- xml

class El:
    """Minimal element tree for POMs (some Python builds ship a broken pyexpat)."""

    def __init__(self, tag):
        self.tag, self.text, self.children = tag, "", []

    def __iter__(self):
        return iter(self.children)

    def find(self, path):
        cur = self
        for name in path.split("/"):
            cur = next((c for c in cur.children if c.tag == name), None)
            if cur is None:
                return None
        return cur

    def findall(self, name):
        return [c for c in self.children if c.tag == name]


_ENT = {"lt": "<", "gt": ">", "amp": "&", "quot": '"', "apos": "'"}


def _unescape(s):
    return re.sub(r"&(#x[0-9a-fA-F]+|#\d+|\w+);",
                  lambda m: chr(int(m.group(1)[2:], 16)) if m.group(1).startswith("#x")
                  else chr(int(m.group(1)[1:])) if m.group(1).startswith("#")
                  else _ENT.get(m.group(1), m.group(0)), s)


def parse_xml(text):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"<\?.*?\?>", "", text, flags=re.S)
    text = re.sub(r"<!DOCTYPE[^>]*>", "", text, flags=re.S)
    text = re.sub(r"<!\[CDATA\[(.*?)\]\]>", lambda m: m.group(1).replace("&", "&amp;").replace("<", "&lt;"),
                  text, flags=re.S)
    root = El("#doc")
    stack = [root]
    pos = 0
    for m in re.finditer(r"<(/?)([\w.:-]+)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>", text):
        stack[-1].text += _unescape(text[pos:m.start()])
        pos = m.end()
        closing, tag, _attrs, selfclose = m.groups()
        tag = tag.split(":")[-1]
        if closing:
            if len(stack) > 1:
                stack.pop()
            continue
        el = El(tag)
        stack[-1].children.append(el)
        if not selfclose:
            stack.append(el)
    return root.children[0]


# ---------------------------------------------------------------- fetching


class Repo:
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir
        self.where = {}  # (group, module, version) -> repo base that served metadata

    def _get(self, url):
        req = urllib.request.Request(url, headers={"User-Agent": "klio-composejvm-fetch/1"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (404, 403, 410):
                return None
            raise

    def metadata(self, g, m, v, ext):
        rel = f"{g.replace('.', '/')}/{m}/{v}/{m}-{v}.{ext}"
        cpath = os.path.join(self.cache_dir, rel)
        miss = cpath + ".missing"
        if os.path.exists(cpath):
            with open(os.path.join(os.path.dirname(cpath), ".repo")) as f:
                self.where[(g, m, v)] = f.read().strip()
            with open(cpath, "rb") as f:
                return f.read()
        if os.path.exists(miss):
            return None
        for base in self._order(g):
            data = self._get(f"{base}/{rel}")
            if data is not None:
                os.makedirs(os.path.dirname(cpath), exist_ok=True)
                with open(cpath, "wb") as f:
                    f.write(data)
                with open(os.path.join(os.path.dirname(cpath), ".repo"), "w") as f:
                    f.write(base)
                self.where[(g, m, v)] = base
                return data
        os.makedirs(os.path.dirname(miss), exist_ok=True)
        open(miss, "w").close()
        return None

    def _order(self, g):
        return REPOS

    def download(self, g, m, v, fname, dest):
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            return
        bases = [self.where[(g, m, v)]] if (g, m, v) in self.where else []
        bases += [b for b in REPOS if b not in bases]
        rel = f"{g.replace('.', '/')}/{m}/{v}/{fname}"
        for base in bases:
            data = self._get(f"{base}/{rel}")
            if data is not None:
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, dest)
                return
        raise SystemExit(f"error: cannot download {rel} from any repository")


# ---------------------------------------------------------------- nodes


class Node:
    """One resolved (group, module, version): its deps and the files it contributes."""

    def __init__(self, g, m, v):
        self.g, self.m, self.v = g, m, v
        self.deps = []         # (group, module, version|None)
        self.constraints = []  # (group, module, version)
        self.platforms = []    # (group, module, version) BOM/platform: constraints only
        self.files = []        # file names relative to the module's version dir
        self.source = ""       # "module" | "pom"
        self.variant = ""
        self.redirect = None   # (group, module, version) for available-at


def _version_of(spec):
    if spec is None:
        return None
    if isinstance(spec, str):
        return spec
    for k in ("strictly", "requires", "prefer"):
        if spec.get(k):
            return pick_range(spec[k])
    return None


def _variant_score(var):
    a = var.get("attributes", {})
    if "org.gradle.docstype" in a:
        return None
    if a.get("org.gradle.category", "library") != "library":
        return None
    usage = a.get("org.gradle.usage")
    if usage == "java-runtime":
        s = 20
    elif usage == "java-api":
        s = 10
    else:
        return None
    pt = a.get("org.jetbrains.kotlin.platform.type")
    if pt is not None and pt != "jvm":
        return None
    env = a.get("org.gradle.jvm.environment")
    if env is not None and env != "standard-jvm":
        return None
    le = a.get("org.gradle.libraryelements")
    if le is not None and le not in ("jar", "classes+resources"):
        return None
    jv = a.get("org.gradle.jvm.version")
    if jv is not None:
        if int(jv) > JDK_VERSION:
            return None
        s += int(jv) / 100.0
    if "stub" in var.get("name", "").lower():
        s -= 5
    return s


def _platform_variant(mod):
    for var in mod.get("variants", []):
        a = var.get("attributes", {})
        if a.get("org.gradle.category") in ("platform", "enforced-platform") and \
                a.get("org.gradle.usage") in ("java-runtime", "java-api", None):
            return var
    return None


class Resolver:
    def __init__(self, repo, excludes):
        self.repo = repo
        self.excludes = excludes
        self.nodes = {}
        self.poms = {}

    # ---- POM model

    def pom_model(self, g, m, v):
        key = (g, m, v)
        if key in self.poms:
            return self.poms[key]
        data = self.repo.metadata(g, m, v, "pom")
        if data is None:
            self.poms[key] = None
            return None
        text = data.decode("utf-8", "replace")
        root = parse_xml(text)

        def t(el, path, default=None):
            x = el.find(path)
            return x.text.strip() if x is not None and x.text else default

        parent = None
        pel = root.find("parent")
        props = {}
        managed = {}
        if pel is not None:
            pg, pm, pv = t(pel, "groupId"), t(pel, "artifactId"), t(pel, "version")
            parent = self.pom_model(pg, pm, pv)
            if parent:
                props.update(parent["props"])
                managed.update(parent["managed"])
        gid = t(root, "groupId") or (pel is not None and t(pel, "groupId")) or g
        ver = t(root, "version") or (pel is not None and t(pel, "version")) or v
        pel_node = root.find("properties")
        if pel_node is not None:
            for p in pel_node:
                props[p.tag] = (p.text or "").strip()
        props.update({
            "project.groupId": gid, "pom.groupId": gid, "groupId": gid,
            "project.version": ver, "pom.version": ver, "version": ver,
            "project.artifactId": m, "artifactId": m,
        })
        if pel is not None:
            props["project.parent.version"] = t(pel, "version")
            props["project.parent.groupId"] = t(pel, "groupId")

        def interp(s):
            if s is None:
                return None
            for _ in range(10):
                n = re.sub(r"\$\{([^}]+)\}", lambda mm: props.get(mm.group(1), mm.group(0)), s)
                if n == s:
                    break
                s = n
            return s

        dm = root.find("dependencyManagement/dependencies")
        if dm is not None:
            for d in dm.findall("dependency"):
                dg, da, dv = interp(t(d, "groupId")), interp(t(d, "artifactId")), interp(t(d, "version"))
                if t(d, "scope") == "import" and t(d, "type") == "pom":
                    bom = self.pom_model(dg, da, pick_range(dv))
                    if bom:
                        for k, val in bom["managed"].items():
                            managed.setdefault(k, val)
                    continue
                managed[(dg, da)] = pick_range(dv)
        deps = []
        dl = root.find("dependencies")
        if dl is not None:
            for d in dl.findall("dependency"):
                scope = t(d, "scope", "compile")
                if scope not in ("compile", "runtime"):
                    continue
                if t(d, "optional", "false") == "true":
                    continue
                typ = t(d, "type", "jar")
                if typ not in ("jar", "bundle"):
                    continue
                dg, da = interp(t(d, "groupId")), interp(t(d, "artifactId"))
                dv = pick_range(interp(t(d, "version"))) or managed.get((dg, da))
                deps.append((dg, da, dv, interp(t(d, "classifier"))))
        model = {
            "props": props, "managed": managed, "deps": deps,
            "packaging": interp(t(root, "packaging", "jar")),
        }
        self.poms[key] = model
        return model

    # ---- node loading

    def load(self, g, m, v):
        key = (g, m, v)
        if key in self.nodes:
            return self.nodes[key]
        n = Node(g, m, v)
        data = self.repo.metadata(g, m, v, "module")
        if data is not None:
            mod = json.loads(data)
            scored = [(s, i, var) for i, var in enumerate(mod.get("variants", []))
                      if (s := _variant_score(var)) is not None]
            if not scored:
                raise SystemExit(f"error: {g}:{m}:{v} has no JVM runtime variant")
            scored.sort(key=lambda x: (-x[0], x[1]))
            var = scored[0][2]
            n.source, n.variant = "module", var.get("name", "")
            at = var.get("available-at")
            if at:
                n.redirect = (at["group"], at["module"], at["version"])
                n.deps.append(n.redirect)
            else:
                for d in var.get("dependencies", []):
                    dv = _version_of(d.get("version"))
                    tgt = (d["group"], d["module"], dv)
                    if d.get("attributes", {}).get("org.gradle.category") in ("platform", "enforced-platform"):
                        n.platforms.append(tgt)
                    else:
                        n.deps.append(tgt)
                for c in var.get("dependencyConstraints", []):
                    cv = _version_of(c.get("version"))
                    if cv:
                        n.constraints.append((c["group"], c["module"], cv))
                n.files = [f["url"] for f in var.get("files", [])]
        else:
            pom = self.pom_model(g, m, v)
            if pom is None:
                raise SystemExit(f"error: {g}:{m}:{v} not found in any repository")
            n.source = "pom"
            for dg, da, dv, cls in pom["deps"]:
                n.deps.append((dg, da, dv))
            if pom["packaging"] in ("jar", "bundle", "maven-plugin", "eclipse-plugin"):
                n.files = [f"{m}-{v}.jar"]
            elif pom["packaging"] == "aar":
                log(f"warning: {g}:{m}:{v} is an Android aar; skipped")
        self.nodes[key] = n
        return n

    def platform_constraints(self, g, m, v):
        data = self.repo.metadata(g, m, v, "module")
        out = []
        if data is not None:
            var = _platform_variant(json.loads(data))
            if var:
                for c in var.get("dependencyConstraints", []):
                    cv = _version_of(c.get("version"))
                    if cv:
                        out.append((c["group"], c["module"], cv))
            return out
        pom = self.pom_model(g, m, v)
        if pom:
            for (dg, da), dv in pom["managed"].items():
                if dv:
                    out.append((dg, da, dv))
        return out

    # ---- graph

    def resolve(self, roots):
        """roots: list of (group, module, version-or-('=', group, module))."""
        selected = {}
        for it in range(100):
            reqs = defaultdict(list)
            cons = defaultdict(list)
            order = OrderedDict()
            queue = []
            for g, m, v in roots:
                if isinstance(v, tuple):
                    v = selected.get((v[1], v[2]))
                    if v is None:
                        continue  # the aligned-to module is not selected yet
                reqs[(g, m)].append(v)
                queue.append((g, m))
            while queue:
                ga = queue.pop(0)
                if ga in order or ga in self.excludes:
                    continue
                v = selected.get(ga) or vmax(reqs[ga] + cons[ga])
                if v is None:
                    raise SystemExit(f"error: no version requested for {ga[0]}:{ga[1]}")
                order[ga] = v
                n = self.load(ga[0], ga[1], v)
                for dg, dm, dv in n.deps:
                    if (dg, dm) in self.excludes:
                        continue
                    if dv:
                        reqs[(dg, dm)].append(dv)
                    queue.append((dg, dm))
                for cg, cm, cv in n.constraints:
                    cons[(cg, cm)].append(cv)
                for pg, pm, pv in n.platforms:
                    if pv:
                        for cg, cm, cv in self.platform_constraints(pg, pm, pv):
                            cons[(cg, cm)].append(cv)
            new = {ga: vmax(reqs[ga] + cons[ga]) for ga in order}
            aligned_pending = any(isinstance(v, tuple) and (v[1], v[2]) in new and (g, m) not in new
                                  for g, m, v in roots)
            if new == selected and not aligned_pending:
                return order, reqs, cons
            selected = new
        raise SystemExit("error: version selection did not converge")


def parse_coord(s):
    parts = s.split(":")
    if len(parts) == 3:
        return (parts[0], parts[1], parts[2])
    if len(parts) == 4 and parts[2].startswith("="):
        return (parts[0], parts[1], ("=", parts[2][1:], parts[3]))
    raise SystemExit(f"error: bad coordinate {s!r} (want group:module:version or group:module:=group2:module2)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("coords", nargs="*")
    ap.add_argument("--jars", default=os.path.join(ORACLE_HOME, "jars"))
    ap.add_argument("--cache", default=os.path.join(ORACLE_HOME, "cache"))
    ap.add_argument("--exclude", action="append", default=[], metavar="group:module")
    ap.add_argument("--keep-stale", action="store_true", help="do not delete jars no longer in the classpath")
    args = ap.parse_args()

    roots = [parse_coord(c) for c in (args.coords or DEFAULT_ROOTS)]
    excludes = {tuple(e.split(":")[:2]) for e in args.exclude}
    repo = Repo(args.cache)
    res = Resolver(repo, excludes)
    order, reqs, cons = res.resolve(roots)

    os.makedirs(args.jars, exist_ok=True)
    jars = []
    log("resolved modules:")
    for (g, m), v in order.items():
        n = res.load(g, m, v)
        asked = sorted({r for r in reqs[(g, m)] if r}, key=functools.cmp_to_key(vcmp))
        bumped = f"  (requested {', '.join(asked)})" if asked and asked != [v] else ""
        if n.redirect:
            log(f"  {g}:{m}:{v} -> {n.redirect[1]}{bumped}")
            continue
        log(f"  {g}:{m}:{v} [{n.source}{':' + n.variant if n.variant else ''}]{bumped}")
        for fname in n.files:
            # one directory per group: JetBrains alias modules reuse androidx
            # artifact names (runtime-desktop-1.12.0.jar exists in both groups)
            os.makedirs(os.path.join(args.jars, g), exist_ok=True)
            dest = os.path.join(args.jars, g, fname)
            repo.download(g, m, v, fname, dest)
            jars.append(dest)

    if not args.keep_stale:
        keep = set(jars)
        for dirpath, _dirs, files in os.walk(args.jars):
            for f in files:
                path = os.path.join(dirpath, f)
                if f.endswith(".jar") and path not in keep:
                    os.remove(path)
                    log(f"  removed stale {os.path.relpath(path, args.jars)}")
    with open(os.path.join(args.jars, "classpath.txt"), "w") as f:
        f.write("\n".join(jars) + "\n")

    print(f"classpath ({len(jars)} jars):")
    for j in jars:
        print(f"  {os.path.relpath(j, args.jars)}")

if __name__ == "__main__":
    main()
