// String / hashmap workload — see klio/strings.kt for the shared spec.
class Rng {
  constructor(seed) { this.s = seed & 0x7fffffff; }
  next() { this.s = (this.s * 1103515245 + 12345) & 0x7fffffff; return this.s; }
}
function main() {
  const n = 500000, vocab = 5000;
  const rng = new Rng(99);
  const freq = new Map();
  const parts = [];
  let totalLen = 0;
  for (let i = 0; i < n; i++) {
    const w = "w" + (rng.next() % vocab);
    freq.set(w, (freq.get(w) || 0) + 1);
    parts.push(w);
    totalLen += w.length + 1;
  }
  const doc = parts.join(" ") + " ";
  let bestWord = "", bestCount = -1;
  for (const [w, c] of freq) { if (c > bestCount) { bestCount = c; bestWord = w; } }
  console.log(`strings: words=${n} distinct=${freq.size} docLen=${doc.length} totalLen=${totalLen} top=${bestWord} count=${bestCount}`);
}
main();
