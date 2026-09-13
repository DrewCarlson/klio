#!/usr/bin/env python3
"""Prove a refactor dropped nothing.

Scans Zig source, skipping comments, and compares the multiset of string
literals, character literals, numbers and identifiers between two revisions of
a file. A pure extraction moves tokens between functions; it does not remove
them. Anything the new revision lost is reported.

Structural tokens do legitimately disappear: a block label consumed by
`break :label x` becoming `return x`, a `var` that became a struct field, a
`continue` that became a returned enum tag. Those show up here too, so read
the report rather than expecting it empty. What must never appear is a lost
string literal or a lost condition identifier.

Usage: token_multiset_check.py <base-rev>[..<head-rev>] <path> [path ...]\n\nWith no head-rev the working tree is compared.
"""
import collections
import re
import subprocess
import sys

TOKEN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*|0[xXbBoO][0-9a-fA-F_]+|\d[\d_]*\.?[\d_]*(?:[eE][-+]?\d+)?')

def scan(src: str):
    strings, chars, out = [], [], []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif c == '\\' and src.startswith('\\\\', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            strings.append(src[i:j])
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == '"' or src[j] == '\n':
                    j += 1
                    break
                j += 1
            strings.append(src[i:j])
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == "'" or src[j] == '\n':
                    j += 1
                    break
                j += 1
            chars.append(src[i:j])
            i = j
        else:
            m = TOKEN.match(src, i)
            if m:
                out.append(m.group(0))
                i = m.end()
            else:
                i += 1
    return (collections.Counter(strings), collections.Counter(chars),
            collections.Counter(out))

def at(rev, path):
    r = subprocess.run(['git', 'show', f'{rev}:{path}'], capture_output=True)
    return None if r.returncode else r.stdout.decode('utf8', 'replace')

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    base, paths = sys.argv[1], sys.argv[2:]
    head = None
    if '..' in base:
        base, head = base.split('..', 1)
    worst = 0
    for p in paths:
        old = at(base, p)
        if old is None:
            print(f'{p}: not present at {base}, skipped')
            continue
        if head:
            new = at(head, p)
            if new is None:
                print(f'{p}: not present at {head}')
                worst = 1
                continue
        else:
            try:
                new = open(p, encoding='utf8', errors='replace').read()
            except FileNotFoundError:
                print(f'{p}: DELETED')
                worst = 1
                continue
        os_, oc, ot = scan(old)
        ns, nc, nt = scan(new)
        lost_s = os_ - ns
        lost_c = oc - nc
        lost_t = ot - nt
        if not (lost_s or lost_c or lost_t):
            print(f'{p}: clean')
            continue
        worst = max(worst, 2 if lost_s or lost_c else 1)
        print(f'{p}:')
        if lost_s:
            print(f'  STRING LITERALS LOST ({sum(lost_s.values())}):')
            for k, v in lost_s.most_common(20):
                print(f'    {v}x {k[:100]}')
        if lost_c:
            print(f'  CHAR LITERALS LOST ({sum(lost_c.values())}): '
                  + ', '.join(f'{v}x {k}' for k, v in lost_c.most_common(20)))
        if lost_t:
            print(f'  identifiers/numbers lost ({sum(lost_t.values())}): '
                  + ', '.join(f'{k}x{v}' for k, v in lost_t.most_common(25)))
    return worst

sys.exit(main())
