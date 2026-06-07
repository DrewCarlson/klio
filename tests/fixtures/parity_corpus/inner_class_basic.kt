class Outer(val x: Int) {
    inner class Inner {
        fun show(): String = "x=$x"
    }
}

fun main() {
    println(Outer(5).Inner().show())
    println(Outer(42).Inner().show())
}
