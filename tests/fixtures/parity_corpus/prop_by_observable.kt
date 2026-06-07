import kotlin.properties.Delegates

var name: String by Delegates.observable("a") { _, old, new ->
    println("$old -> $new")
}

fun main() {
    name = "b"
    name = "c"
    println(name)
}
