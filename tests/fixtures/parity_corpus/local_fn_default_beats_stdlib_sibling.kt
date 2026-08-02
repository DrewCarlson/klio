fun main() {
    fun check(a: Float, b: Float, expected: Float? = null) {
        println("local " + a + " " + b + " " + expected)
    }
    repeat(2) {
        check(1.5f, 0.5f)
    }
    check(2.5f, 0.5f, 3.0f)
}
