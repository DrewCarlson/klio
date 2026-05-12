abstract class Pet {
    abstract val name: String
    abstract fun sound(): String
    fun describe(): String = "$name says ${sound()}"
}

class Dog(override val name: String) : Pet() {
    override fun sound(): String = "woof"
}

class Cat(override val name: String) : Pet() {
    override fun sound(): String = "meow"
}

class Owner(val owner: String) {
    inner class Visit(val pet: Pet) {
        fun report(): String = "$owner brought ${pet.name}: ${pet.describe()}"
    }
}

fun main() {
    val pets: List<Pet> = listOf(Dog("Rex"), Cat("Whiskers"))
    for (p in pets) println(p.describe())
    val o = Owner("Alice")
    println(o.Visit(Dog("Buddy")).report())
    println(o.Visit(Cat("Mittens")).report())
}
