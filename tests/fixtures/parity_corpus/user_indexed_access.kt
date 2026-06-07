class Matrix(val rows: Int, val cols: Int) {
    private val data = IntArray(rows * cols)
    operator fun get(r: Int, c: Int): Int = data[r * cols + c]
    operator fun set(r: Int, c: Int, v: Int) { data[r * cols + c] = v }
}

fun main() {
    val m = Matrix(2, 3)
    m[0, 0] = 1
    m[0, 1] = 2
    m[1, 2] = 9
    println(m[0, 0])
    println(m[0, 1])
    println(m[1, 2])
    m[1, 2] += 10
    println(m[1, 2])
}
