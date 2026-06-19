# Large primitive-array workload — see klio/numeric.kt for the shared spec.
def main():
    limit = 10000000
    sieve = bytearray(limit + 1)
    count = 0
    i = 2
    while i <= limit:
        if sieve[i] == 0:
            count += 1
            if i <= 3163:
                j = i * i
                while j <= limit:
                    sieve[j] = 1
                    j += i
        i += 1
    k = 100000
    taken = 0
    acc = 0
    p = 2
    while p <= limit and taken < k:
        if sieve[p] == 0:
            acc = (acc + p * p) % 1000000007
            taken += 1
        p += 1
    print(f"numeric: limit={limit} primes={count} firstK={taken} checksum={acc}")

main()
