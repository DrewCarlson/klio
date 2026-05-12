fun main() {
    val o = object {
        val x = 1
        fun f(): Int = x + 1
    }
    println(o.f())
}
