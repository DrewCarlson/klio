// A bare call inside a class binds the class's OWN member -- private and
// inline included -- ahead of any same-named top-level inline extension,
// even when several such extensions are in scope and none matches the
// receiver chain.

abstract class Rec(val id: Int)
class RecImpl(id: Int) : Rec(id)

interface StateObj {
    val firstRec: Rec
}

inline fun <T : Rec, R> T.withCurrent(block: (r: T) -> R): R {
    println("ext-record")
    return block(this)
}

class OtherList<T>
class OtherSet<T>

internal inline fun <R, T> OtherList<T>.withCurrent(block: (Int) -> R): R {
    println("ext-list")
    return block(1)
}

internal inline fun <R, T> OtherSet<T>.withCurrent(block: (Int) -> R): R {
    println("ext-set")
    return block(2)
}

class Holder<K, V> : StateObj {
    override val firstRec: Rec = RecImpl(42)

    private inline fun <R> withCurrent(block: RecImpl.() -> R): R {
        println("member")
        return (firstRec as RecImpl).block()
    }

    private inline fun update(block: (Int) -> Int): Int = withCurrent { block(id) }

    fun clear(): Int = update { it * 2 }
}

class ForwardPrivateOverloads {
    fun chooseBoth(): String = choose(1) + "/" + choose("x")

    private fun choose(value: Int): String = "int:$value"
    private fun choose(value: String): String = "string:$value"
}

fun main() {
    println(Holder<Int, Float>().clear())
    println(RecImpl(7).withCurrent { it.id })
    println(OtherList<Int>().withCurrent { it + 10 })
    println(ForwardPrivateOverloads().chooseBoth())
}
