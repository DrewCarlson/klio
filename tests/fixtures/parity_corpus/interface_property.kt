interface HasName {
    val name: String
    fun hello(): String = "hello, $name"
}

class Person(override val name: String) : HasName

fun main() {
    val p = Person("Ada")
    println(p.name)
    println(p.hello())
}
