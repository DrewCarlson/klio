class Outer(val tag: String) {
    fun run(): String {
        class Helper(val v: Int) {
            fun render(): String = "$tag:$v"
        }
        return Helper(9).render()
    }
}

fun main() {
    println(Outer("T").run())
}
