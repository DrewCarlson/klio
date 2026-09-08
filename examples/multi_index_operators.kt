// A user-declared multi-index operator `get(i, j)` / `set(i, j, v)` handles
// `a[i, j]` and `a[i, j] = v`, even on a builtin collection whose own
// indexed get/set take a single index. The builtin no longer swallows the
// extra index.
operator fun MutableList<String>.get(i: Int, j: Int): String = this[i + j]
operator fun MutableList<String>.set(i: Int, j: Int, v: String) { this[i + j] = v }

class Grid(val cols: Int, val cells: MutableList<Int>) {
    operator fun get(r: Int, c: Int): Int = cells[r * cols + c]
    operator fun set(r: Int, c: Int, v: Int) { cells[r * cols + c] = v }
}

fun main() {
    val s = mutableListOf("", "", "")
    s[1, 1] = "OK"
    println(s[0, 2])
    println(s[1])

    val g = Grid(2, mutableListOf(0, 0, 0, 0))
    g[1, 0] = 5
    g[0, 1] = 7
    println(g[1, 0])
    println(g[0, 1])
}
