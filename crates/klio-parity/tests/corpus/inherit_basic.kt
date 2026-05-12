open class Animal(val name: String) {
    fun introduce(): String = "I am $name"
}

class Dog(name: String) : Animal(name)

fun main() {
    val d = Dog("Rex")
    println(d.name)
    println(d.introduce())
}
