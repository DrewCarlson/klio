abstract class Base {
    abstract val label: String
}

class Sub : Base() {
    val label: String = "sub"
}

fun main() {
    println(Sub().label)
}
