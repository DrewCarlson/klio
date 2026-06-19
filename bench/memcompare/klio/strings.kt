// String / hashmap workload: generate many words drawn from a bounded
// vocabulary, count word frequencies in a map, build one large concatenated
// document, then report the most frequent word. Stresses string allocation and
// hash-map churn.

class Rng(seed: Long) {
    private var s = seed and 0x7fffffffL
    fun next(): Long {
        s = (s * 1103515245L + 12345L) and 0x7fffffffL
        return s
    }
}

fun main() {
    val n = 500_000
    val vocab = 5000
    val rng = Rng(99L)
    val freq = HashMap<String, Int>()
    val sb = StringBuilder()
    var totalLen = 0L
    for (i in 0 until n) {
        val w = "w" + (rng.next() % vocab)
        freq[w] = (freq[w] ?: 0) + 1
        sb.append(w)
        sb.append(' ')
        totalLen += w.length + 1
    }
    val doc = sb.toString()
    var bestWord = ""
    var bestCount = -1
    for ((w, c) in freq) {
        if (c > bestCount) {
            bestCount = c
            bestWord = w
        }
    }
    println("strings: words=$n distinct=${freq.size} docLen=${doc.length} totalLen=$totalLen top=$bestWord count=$bestCount")
}
