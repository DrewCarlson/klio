interface Greeter { fun hello(): String }

fun main() {
    val g = object : Greeter {
        override fun hello() = name
        val name = "world"
    }
    println(g.hello())
}
