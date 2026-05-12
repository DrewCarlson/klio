// Collections, sequences-ops, and ranges (M9). Passes parity against
// kotlinc-native 2.3.21.

fun main() {
    // ----- List basics -----
    val nums = listOf(1, 2, 3, 4, 5)
    println(nums)                    // [1, 2, 3, 4, 5]
    println(nums.size)               // 5
    println(nums.first())            // 1
    println(nums.last())             // 5
    println(nums[2])                 // 3
    println(nums.contains(3))        // true
    println(nums.joinToString(", ")) // 1, 2, 3, 4, 5

    // ----- Higher-order ops -----
    println(nums.map { it * it })            // [1, 4, 9, 16, 25]
    println(nums.filter { it % 2 == 0 })     // [2, 4]
    println(nums.sumOf { it })               // 15
    println(nums.fold(100) { acc, x -> acc + x })  // 115
    println(nums.reduce { acc, x -> acc + x })     // 15
    println(nums.any { it > 4 })             // true
    println(nums.all { it < 100 })           // true
    println(nums.count { it > 2 })           // 3
    println(nums.find { it > 3 })            // 4

    // ----- Mutable list -----
    val mut = mutableListOf(10, 20)
    mut.add(30)
    mut.removeAt(0)
    println(mut)                     // [20, 30]

    // ----- Map -----
    val ages = mapOf("alice" to 30, "bob" to 25, "carol" to 35)
    println(ages)                    // {alice=30, bob=25, carol=35}
    println(ages["alice"])           // 30
    println(ages.size)               // 3
    println(ages.keys)               // [alice, bob, carol]
    println(ages.values)             // [30, 25, 35]
    for (entry in ages) {
        println("${entry.key} is ${entry.value}")
    }

    // ----- Mutable map -----
    val scores = mutableMapOf("a" to 1)
    scores.put("b", 2)
    scores.remove("a")
    println(scores)                  // {b=2}

    // ----- Set -----
    val unique = setOf(1, 2, 2, 3, 3, 3)
    println(unique)                  // [1, 2, 3]
    println(unique.size)             // 3

    // ----- Pair + to infix -----
    val coord = 10 to 20
    println(coord)                   // (10, 20)
    println("${coord.first}, ${coord.second}")  // 10, 20

    // ----- M9b: sorting, distinct, grouping -----
    val noisy = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(noisy.sorted())                                     // [1, 1, 2, 3, 4, 5, 6, 9]
    println(noisy.sortedDescending())                           // [9, 6, 5, 4, 3, 2, 1, 1]
    println(noisy.distinct())                                   // [3, 1, 4, 5, 9, 2, 6]
    println(noisy.groupBy { it % 3 })                           // {0=[3, 9, 6], 1=[1, 1, 4], 2=[5, 2]}
    println(noisy.partition { it > 3 })                         // ([4, 5, 9, 6], [3, 1, 1, 2])

    // ----- flatMap, zip -----
    println(listOf(1, 2, 3).flatMap { listOf(it, it * 10) })    // [1, 10, 2, 20, 3, 30]
    println(listOf("a", "b").zip(listOf(1, 2, 3)))              // [(a, 1), (b, 2)]

    // ----- take/drop/slice -----
    val seq = listOf(1, 2, 3, 4, 5, 6)
    println(seq.take(3))                                         // [1, 2, 3]
    println(seq.drop(3))                                         // [4, 5, 6]
    println(seq.slice(1..3))                                     // [2, 3, 4]

    // ----- plus/minus + set ops -----
    println(listOf(1, 2, 3).plus(listOf(4, 5)))                 // [1, 2, 3, 4, 5]
    println(setOf(1, 2, 3).union(setOf(3, 4, 5)))               // [1, 2, 3, 4, 5]
    println(setOf(1, 2, 3).intersect(setOf(2, 3, 4)))           // [2, 3]

    // ----- Progressions -----
    for (i in 1..5 step 2) print(i)
    println()                                                    // 135
    for (i in 5 downTo 1) print(i)
    println()                                                    // 54321
    println(1..10 step 3)                                        // 1..10 step 3

    // ----- Destructuring in for-loops -----
    for ((k, v) in mapOf("x" to 1, "y" to 2)) {
        println("$k=$v")
    }

    // ----- M9c: named constructors -----
    val al = ArrayList<Int>()
    al.add(1)
    al.add(2)
    println(al)                                         // [1, 2]

    // ----- chunked / windowed -----
    val chunks = listOf(1, 2, 3, 4, 5, 6, 7).chunked(3)
    println(chunks)                                     // [[1, 2, 3], [4, 5, 6], [7]]
    val windows = listOf(1, 2, 3, 4, 5).windowed(3)
    println(windows)                                    // [[1, 2, 3], [2, 3, 4], [3, 4, 5]]

    // ----- String collection helpers -----
    println("hello".toList())                           // [h, e, l, l, o]
    println("a,b,c".split(","))                         // [a, b, c]
    println("abcdef".chunked(2))                        // [ab, cd, ef]

    // ----- Comparator + sortedWith -----
    val words = listOf("banana", "apple", "cherry")
    println(words.sortedWith(compareBy { it.length }))  // [apple, banana, cherry]

    // ----- Sequence (lazy) -----
    val s = listOf(1, 2, 3, 4, 5).asSequence().map { it * 10 }.filter { it > 20 }
    println(s.toList())                                 // [30, 40, 50]
    println(s.count())                                  // 3

    // ----- M9d: thenByDescending -----
    val pairs = listOf("a" to 3, "b" to 1, "a" to 1, "b" to 3, "a" to 2)
    println(pairs.sortedWith(compareBy<Pair<String, Int>> { it.first }.thenByDescending { it.second }))

    // ----- joinToString with transform and limit -----
    println(listOf(1, 2, 3, 4, 5).joinToString(", ", "[", "]") { "x=$it" })
    println(listOf(1, 2, 3, 4, 5).joinToString(", ", "[", "]", 3, "..."))

    // ----- generateSequence: lazy, bounded by the terminal op -----
    println(generateSequence(1) { it + 1 }.take(5).toList())
    println(generateSequence(2) { it * 2 }.takeWhile { it < 100 }.toList())
    println(generateSequence(1) { if (it < 5) it + 1 else null }.toList())

    // ----- M9e: aggregations + Sequence sort -----
    val agg = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(agg.sum())                    // 31
    println(agg.max())                    // 9
    println(agg.average())                // 3.875
    println(agg.indices)                  // 0..7
    println(agg.lastIndex)                // 7
    println(listOf("a" to 1, "b" to 2).toMap())  // {a=1, b=2}

    // Sort on a lazy Sequence: buffer-then-emit.
    println(agg.asSequence().filter { it > 1 }.sorted().toList())     // [2, 3, 4, 5, 6, 9]
    println(generateSequence(1) { it + 1 }.take(5).sortedDescending().toList())  // [5, 4, 3, 2, 1]
}
