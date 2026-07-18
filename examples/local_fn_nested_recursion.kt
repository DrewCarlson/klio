// A nested local function calling back into its enclosing local function:
// the enclosing fn's plain name only binds after its body lowers, so the
// nested body reaches it through the pre-bound overload cell.

fun countdown(n: Int): Int {
    fun step(g: Int): Int {
        fun inner(x: Int): Int = step(x)
        return if (g <= 0) 0 else inner(g - 1) + 1
    }
    return step(n)
}

fun scan(depth: Int): Int {
    fun refFor(g: Int): Int? {
        fun traverse(g2: Int) {
            if (g2 > 0) {
                refFor(g2 - 1)?.let { println("saw $it") }
                traverse(g2 - 1)
            }
        }
        traverse(g)
        return if (g == 0) null else g
    }
    return refFor(depth) ?: -1
}

fun main() {
    println(countdown(3))
    println(scan(2))
}
