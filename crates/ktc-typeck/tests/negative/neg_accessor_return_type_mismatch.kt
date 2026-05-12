// Accessor explicitly annotates a return type that disagrees with the
// property's declared type. Expect T0018.

class Box {
    val x: Int
        get(): String = "hi"
}

fun main() {
    println(Box())
}
