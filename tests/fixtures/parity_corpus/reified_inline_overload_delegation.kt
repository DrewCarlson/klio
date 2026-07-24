class Kind<T>

interface Marker

class Marked : Marker

inline fun <reified T> Any.matches(kind: Kind<T>): Boolean {
    return matches(kind, false)
}

inline fun <reified T> Any.matches(
    kind: Kind<T>,
    ignored: Boolean,
): Boolean {
    return this is T
}

fun main() {
    println(Marked().matches(Kind<Marker>()))
    println(Any().matches(Kind<Marker>()))
}
