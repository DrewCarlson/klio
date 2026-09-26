// `klio check --engine sema` names kotlinc's diagnostics; `@Suppress`
// silences the one it names over what it annotates.
fun greet(a: Int) = a
fun greet(b: Int) = b

@Suppress("UNRESOLVED_REFERENCE")
fun quiet() = missingButSuppressed

class Box {
    val size = 1
    val size = 2
}

fun main() {
    println(missing)
    val label: Strin = "box"
    println(label)
}
