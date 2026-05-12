fun process(items: List<Int>, threshold: Int): Int {
    var count = 0
    items.forEach { item ->
        if (item > threshold) return -1
        count++
    }
    return count
}

fun safeFind(items: List<Int>, target: Int): Int? {
    items.forEachIndexed { idx, item ->
        if (item == target) return idx
    }
    return null
}

fun main() {
    println(process(listOf(1, 2, 3), 5))
    println(process(listOf(1, 2, 9, 4), 5))
    println(safeFind(listOf(10, 20, 30), 20))
    println(safeFind(listOf(10, 20, 30), 99))
}
