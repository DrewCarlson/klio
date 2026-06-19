// Large primitive-array workload — see klio/numeric.kt for the shared spec.
function main() {
  const limit = 10000000;
  const sieve = new Uint8Array(limit + 1);
  let count = 0;
  for (let i = 2; i <= limit; i++) {
    if (sieve[i] === 0) {
      count++;
      if (i <= 3163) { for (let j = i * i; j <= limit; j += i) sieve[j] = 1; }
    }
  }
  const k = 100000;
  let taken = 0, acc = 0n;
  for (let p = 2; p <= limit && taken < k; p++) {
    if (sieve[p] === 0) { acc = (acc + BigInt(p) * BigInt(p)) % 1000000007n; taken++; }
  }
  console.log(`numeric: limit=${limit} primes=${count} firstK=${taken} checksum=${acc}`);
}
main();
