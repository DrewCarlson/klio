import kotlin.reflect.KMutableProperty1

class Bag { var name: String? = null }

class Setter<T>(val prop: KMutableProperty1<Bag, T?>) {
    fun set(b: Bag, v: T) { prop.set(b, v) }
}

fun main() {
    val s = Setter(Bag::name)
    val input = "hello America/New_York]"
    val b = Bag()
    s.set(b, input.substring(6, 22))
    println("via prop-ref -> " + b.name)

    // and through a plain lambda setter
    val fn: (Bag, String) -> Unit = { bag, v -> bag.name = v }
    val b2 = Bag()
    fn(b2, input.substring(6, 22))
    println("via lambda   -> " + b2.name)
}
