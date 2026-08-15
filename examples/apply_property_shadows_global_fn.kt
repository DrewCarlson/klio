// A bare name inside a spliced receiver lambda resolves the receiver's
// PROPERTY even when a same-named top-level function exists — kotlinc only
// considers the function in call position.

class Box {
    val parameters = mutableListOf<String>()
    var port = 0
}

fun parameters(builder: StringBuilder.() -> Unit): String =
    StringBuilder().apply(builder).toString()

fun main() {
    val b = Box().apply {
        parameters.add("a")
        parameters.add("b")
        port = 8080
    }
    println(b.parameters)
    println(b.port)
    println(parameters { append("fn-still-callable") })
    println("done")
}
