fun bad(vararg xs: Int, vararg ys: Int): Int = xs.size + ys.size

fun main() {
    println(bad(1, 2))
}
