package lib

fun helper(): String = "helper-ran"
val flag: Int = 42
class Box(val n: Int)

fun greet(name: String = "world"): String = "hi $name"
fun sum(vararg xs: Int): Int { var s = 0; for (x in xs) s += x; return s }
fun combo(label: String = "x", body: () -> Unit): String { body(); return label }
fun vlam(vararg xs: Int, body: () -> Unit): Int { body(); var s = 0; for (x in xs) s += x; return s }
