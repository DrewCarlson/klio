// `in y` in a `when` branch is `y.contains(subject)` exactly as the binary
// form is: the `contains` in scope binds, a local extension operator
// included, and `!in` negates it.
enum class E { ONE, TWO, THREE }

class Bag(val items: List<E>)

operator fun Bag.contains(e: E) = e in items

fun classify(e: E): String {
    operator fun E.contains(other: E) = other.ordinal <= ordinal
    return when (e) {
        in E.ONE -> "at most ONE"
        in E.TWO -> "at most TWO"
        else -> "beyond"
    }
}

fun never(e: E): String {
    operator fun E.contains(other: E) = false
    return when (e) {
        in E.ONE, in E.TWO, in E.THREE -> "contained"
        else -> "never contained"
    }
}

fun main() {
    println(E.entries.map { classify(it) })
    println(E.entries.map { never(it) })
    val bag = Bag(listOf(E.ONE, E.THREE))
    for (e in E.entries) {
        println(when (e) {
            in bag -> "$e in bag"
            else -> "$e not in bag"
        })
        println(when (e) {
            !in bag -> "$e absent"
            else -> "$e present"
        })
    }
    val x: E? = null
    println(when (x) {
        E.ONE -> "one"
        else -> "no subject"
    })
}
