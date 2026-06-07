open class Animal(val name: String) {
    open fun speak(): String = "..."
    val kind: String get() = "animal"
}
class Dog(name: String) : Animal(name) {
    override fun speak(): String = "woof"
}
class Box(val value: Int) {
    fun doubled(): Int = value * 2
}
fun shout(s: String): String = s.uppercase()

fun main() {
    val b = Box(21)
    val prop = b::value
    println(prop())
    val meth = b::doubled
    println(meth())

    val boxes = listOf(Box(1), Box(2), Box(3))
    println(boxes.map(Box::value))
    println(boxes.map(Box::doubled))

    val d = Dog("Rex")
    val nameRef = d::name
    println(nameRef())
    val kindRef = d::kind
    println(kindRef())
    val speakRef = d::speak
    println(speakRef())

    println(listOf("a", "b").map(::shout))
    println(listOf(Dog("A"), Dog("B")).map(Animal::name))
    println(listOf(Dog("A"), Dog("B")).map(Animal::speak))
    println(listOf(Dog("A"), Dog("B")).map(Animal::kind))
}
