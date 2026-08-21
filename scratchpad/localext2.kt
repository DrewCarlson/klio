fun outer() {
    fun Int.pad() = toString().padStart(2, '0')

    // Called from a SIBLING local function declared after it.
    fun render(n: Int): String = n.pad()

    // Called from a local function declared BEFORE use, via a loop.
    fun renderAll(xs: List<Int>): String = xs.joinToString(",") { it.pad() }

    println("direct  = " + 5.pad())
    println("nested  = " + render(6))
    println("lambda  = " + renderAll(listOf(7, 88)))
}

fun main() { outer() }
