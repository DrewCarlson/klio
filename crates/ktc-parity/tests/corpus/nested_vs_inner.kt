class Container {
    class Nested {
        fun label(): String = "nested"
    }
    inner class Inner {
        fun label(): String = "inner"
    }
}

fun main() {
    val n = Container.Nested()
    val i = Container().Inner()
    println(n.label())
    println(i.label())
}
