class C(p: Int) {
    fun get(): Int = p
}

fun main() {
    println(C(7).get())
}
