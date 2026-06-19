# Object-graph / GC workload — see klio/collections.kt for the shared spec.
class Rng:
    def __init__(self, seed):
        self.s = seed & 0x7fffffff
    def next(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7fffffff
        return self.s

def main():
    n = 1000000
    groups = 1000
    rng = Rng(12345)
    by_key = {}
    total_sum = 0
    for i in range(n):
        v = rng.next()
        k = i % groups
        by_key.setdefault(k, []).append(v)
        total_sum += v
    sums = []
    for k, vs in by_key.items():
        s = 0
        for v in vs:
            s += v
        sums.append((k, s))
    sums.sort(key=lambda p: p[1], reverse=True)
    top = sums[0]
    print(f"collections: records={n} groups={len(by_key)} totalSum={total_sum} topKey={top[0]} topSum={top[1]}")

main()
