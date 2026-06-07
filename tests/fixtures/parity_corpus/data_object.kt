data object Singleton {
    val tag: String = "S"
}

fun main() {
    println(Singleton)
    println(Singleton.toString())
    println(Singleton === Singleton)
    println(Singleton == Singleton)
    println(Singleton.tag)
}
