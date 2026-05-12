val topProp: Int = 1
var mutTop = "hi"

fun add(a: Int, b: Int): Int {
    return a + b
}

fun greet(name: String = "world"): String {
    val message = "hi $name"
    return message
}
