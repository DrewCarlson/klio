fun main() {
    val s = setOf(1, 2, 2, 3, 3, 3)
    println(s)
    println(s.size)
    println(s.contains(2))
    println(s.contains(99))

    val ms = mutableSetOf(1, 2, 3)
    ms.add(4)
    ms.add(2) // already present
    println(ms)
    println(ms.size)
    ms.remove(1)
    println(ms)
}
