// A reified inline extension called on a CLASS PROPERTY receiver. The splice is
// what gives `is T` a real class to test: an overload set (here the two-arg form
// delegating to the three-arg one) can only be told apart by the receiver's
// declared type, so the receiver must be typed from the enclosing class's
// members, not just from locals and parameters. Without that the splice bails to
// a plain member dispatch, `T` never binds, and `is T` accepts any non-null
// value — a Square would answer to a Kind<Circle>.

class Kind<T>(val mask: Int)

class Circle {
    fun label(): String = "circle"
}

class Square {
    fun label(): String = "square"
}

object Kinds {
    val circle: Kind<Circle>
        get() = Kind(1)
}

inline fun <reified T> Any.forKind(kind: Kind<T>, block: (T) -> Unit) = forKind(kind, false, block)

inline fun <reified T> Any.forKind(kind: Kind<T>, deep: Boolean, block: (T) -> Unit) {
    if (this is T) block(this)
}

class Holder(val value: Any) {
    fun describe(): String {
        var out = "none"
        value.forKind(Kinds.circle) { out = it.label() }
        return out
    }
}

fun main() {
    println(Holder(Circle()).describe())
    println(Holder(Square()).describe())
}
