// Explicit backing fields: a `val` property whose storage is declared with
// `field[: Type][= init]`. Inside the declaring scope reads see the FIELD
// type (the mutable view); outside they see the property type.

// Top-level: the whole file is the declaring scope, so `history` is a
// MutableList<String> everywhere below.
val history: List<String>
    field = mutableListOf<String>()

class Cart {
    // The classic use case: expose a read-only List, mutate internally.
    val items: List<String>
        field = mutableListOf<String>()

    fun add(item: String) {
        items.add(item)
        history.add("add:" + item)
    }
}

class Meter {
    // The field type may be any subtype of the property type.
    val reading: Number
        field: Int = 40

    fun bump() = reading + 2
}

class Batch {
    // Deferred initialization: a field with no initializer must be
    // definitely assigned in the init block.
    val ids: List<Int>
        field: MutableList<Int>

    init {
        ids = mutableListOf(1, 2)
    }

    fun grow(n: Int) {
        ids.add(n)
    }
}

fun main() {
    val cart = Cart()
    cart.add("apple")
    cart.add("pear")
    println(cart.items)
    println(cart.items.size)

    val meter = Meter()
    println(meter.bump())

    val batch = Batch()
    batch.grow(3)
    println(batch.ids)

    history.add("done")
    println(history)
}
