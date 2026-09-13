#!/usr/bin/env python3
"""Prove a change touched only comments.

Strips every comment and all whitespace-only differences from the given Zig
files at two git revisions (or working tree) and reports any file whose code
text differs. A comment-rewrite pass must come back clean.

Usage: comment_only_check.py <base-rev> [path ...]
"""
import subprocess
import sys
import os

def strip(src: str) -> str:
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                if src[j] == '\n':
                    break
                j += 1
            out.append(src[i:j])
            i = j
        elif c == '\\' and src.startswith('\\\\', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(src[i:j])
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == "'":
                    j += 1
                    break
                if src[j] == '\n':
                    break
                j += 1
            out.append(src[i:j])
            i = j
        elif c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    text = ''.join(out)
    return '\n'.join(ln.strip() for ln in text.split('\n') if ln.strip())

def at_rev(rev, path):
    r = subprocess.run(['git', 'show', f'{rev}:{path}'], capture_output=True)
    return None if r.returncode else r.stdout.decode('utf8', 'replace')

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    base = sys.argv[1]
    paths = []
    for arg in sys.argv[2:]:
        if os.path.isdir(arg):
            for dp, _, fns in os.walk(arg):
                paths += [os.path.join(dp, f) for f in fns if f.endswith('.zig')]
        else:
            paths.append(arg)
    if not paths:
        r = subprocess.run(['git', 'diff', '--name-only', base], capture_output=True, text=True)
        paths = [p for p in r.stdout.split('\n') if p.endswith('.zig')]
    bad = []
    for p in paths:
        old = at_rev(base, p)
        if old is None:
            bad.append((p, 'added/renamed'))
            continue
        if not os.path.exists(p):
            bad.append((p, 'deleted'))
            continue
        new = open(p, encoding='utf8', errors='replace').read()
        if strip(old) != strip(new):
            bad.append((p, 'CODE CHANGED'))
    for p, why in bad:
        print(f'{why}: {p}')
    print(f'checked {len(paths)} files, {len(bad)} with non-comment changes')
    return 1 if bad else 0

sys.exit(main())
