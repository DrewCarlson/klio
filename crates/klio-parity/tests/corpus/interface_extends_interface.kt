interface A {
    fun thing(): String
}

interface B : A {
    override fun thing(): String = "from B"
}

class C : B

fun main() {
    val c = C()
    println(c.thing())
}
