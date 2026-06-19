// Large primitive-array workload: sieve of Eratosthenes up to a bound, then a
// reduction over the first K primes. Stresses one big flat array with little GC
// pressure — the opposite profile from the collections workload.

fun main() {
    val limit = 10_000_000
    val sieve = BooleanArray(limit + 1)
    var count = 0
    var i = 2
    while (i <= limit) {
        if (!sieve[i]) {
            count++
            if (i <= 3163) {
                var j = i * i
                while (j <= limit) { sieve[j] = true; j += i }
            }
        }
        i++
    }
    val k = 100_000
    var taken = 0
    var acc = 0L
    var p = 2
    while (p <= limit && taken < k) {
        if (!sieve[p]) {
            acc = (acc + p.toLong() * p) % 1_000_000_007L
            taken++
        }
        p++
    }
    println("numeric: limit=$limit primes=$count firstK=$taken checksum=$acc")
}
