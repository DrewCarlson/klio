abstract class Animal {
    abstract val name: String
    fun greet(): String = "hello, I am $name"
}

class Dog : Animal() {
    override val name: String = "Rex"
}

class Cat(override val name: String) : Animal()

fun main() {
    println(Dog().greet())
    println(Cat("Whiskers").greet())
}
