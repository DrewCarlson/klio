open class Animal {
    open fun speak(): String = "generic sound"
}

class Dog : Animal() {
    override fun speak(): String = "woof"
}

class Cat : Animal() {
    override fun speak(): String = "meow"
}

fun describe(a: Animal): String = a.speak()

fun main() {
    val a: Animal = Animal()
    val d: Animal = Dog()
    val c: Animal = Cat()
    println(describe(a))
    println(describe(d))
    println(describe(c))
}
