open class Base(val tag: String) {
    init {
        println("Base.init tag=$tag")
    }
}

class Derived(tag: String, val extra: Int) : Base(tag) {
    init {
        println("Derived.init extra=$extra tag=$tag")
    }
}

fun main() {
    val d = Derived("hello", 42)
    println("done: ${d.tag} ${d.extra}")
}
