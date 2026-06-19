// Object-graph / GC workload — see klio/collections.kt for the shared spec.
class Rng {
  constructor(seed) { this.s = seed & 0x7fffffff; }
  next() { this.s = (this.s * 1103515245 + 12345) & 0x7fffffff; return this.s; }
}
function main() {
  const n = 1000000, groups = 1000;
  const rng = new Rng(12345);
  const byKey = new Map();
  let totalSum = 0;
  for (let i = 0; i < n; i++) {
    const v = rng.next();
    const k = i % groups;
    let arr = byKey.get(k);
    if (arr === undefined) { arr = []; byKey.set(k, arr); }
    arr.push(v);
    totalSum += v;
  }
  const sums = [];
  for (const [k, vs] of byKey) {
    let s = 0;
    for (const v of vs) s += v;
    sums.push([k, s]);
  }
  sums.sort((a, b) => b[1] - a[1]);
  const top = sums[0];
  console.log(`collections: records=${n} groups=${byKey.size} totalSum=${totalSum} topKey=${top[0]} topSum=${top[1]}`);
}
main();
