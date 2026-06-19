# String / hashmap workload — see klio/strings.kt for the shared spec.
class Rng:
    def __init__(self, seed):
        self.s = seed & 0x7fffffff
    def next(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7fffffff
        return self.s

def main():
    n = 500000
    vocab = 5000
    rng = Rng(99)
    freq = {}
    parts = []
    total_len = 0
    for i in range(n):
        w = "w" + str(rng.next() % vocab)
        freq[w] = freq.get(w, 0) + 1
        parts.append(w)
        total_len += len(w) + 1
    doc = " ".join(parts) + " "
    best_word, best_count = "", -1
    for w, c in freq.items():
        if c > best_count:
            best_count = c
            best_word = w
    print(f"strings: words={n} distinct={len(freq)} docLen={len(doc)} totalLen={total_len} top={best_word} count={best_count}")

main()
