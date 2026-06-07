open class Named(val name: String) {
    open fun greet(): String = "hello $name"
}

fun main() {
    val o = object : Named("Anna") {
        override fun greet(): String = "$name!"
    }
    println(o.greet())
}
