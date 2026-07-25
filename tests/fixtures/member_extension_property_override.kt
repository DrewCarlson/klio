package sample

abstract class ExtensionOwner {
    abstract val String.rank: Int

    fun rankOf(value: String): Int = value.rank
}

class FirstOwner : ExtensionOwner() {
    override val String.rank: Int
        get() = 1
}

class SecondOwner : ExtensionOwner() {
    override val String.rank: Int
        get() = 2
}

fun main() {
    println(FirstOwner().rankOf("x"))
    println(SecondOwner().rankOf("x"))
}
