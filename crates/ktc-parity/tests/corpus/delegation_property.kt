interface Named {
    val label: String
}

class Plate(override val label: String) : Named

class Wrap(n: Named) : Named by n

fun main() {
    val w = Wrap(Plate("hello"))
    println(w.label)
}
