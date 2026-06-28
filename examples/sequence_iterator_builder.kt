// The `iterator { ... }` builder: a bare call with a trailing lambda resolves
// to the inline builder that yields values lazily, not to the no-arg
// `Iterator<T>.iterator()` extension of the same name.
fun main() {
    val it = iterator<Int> {
        yield(1)
        yield(2)
        yield(3)
    }
    println(it.next())
    println(it.next())
    println(it.next())

    // Consumed by a `while` over hasNext()/next().
    val letters = iterator {
        yield("a")
        yield("b")
    }
    while (letters.hasNext()) {
        print(letters.next())
    }
    println()

    // A function whose body is the builder, then drained into a list.
    fun tens(): Iterator<Int> = iterator {
        var n = 10
        while (n <= 30) {
            yield(n)
            n += 10
        }
    }
    val drained = tens()
    println(drained.next() + drained.next() + drained.next())

    // The sibling `sequence { }` builder still works alongside it.
    println(sequence { yield(7); yield(8) }.toList())
}
