// Every collection's iterator is a `MutableIterator`, as a JVM collection's is, a list's
// `listIterator()` a `MutableListIterator`, a primitive array's its `IntIterator` (or
// `LongIterator`, ...), a range's too, and a string's a `CharIterator`; an `Array`'s and a
// sequence's are plain iterators. Each answers its type tests and casts as kotlinc's does.

fun describe(label: String, x: Any) {
    val kinds = listOfNotNull(
        "Iterator".takeIf { x is Iterator<*> },
        "MutableIterator".takeIf { x is MutableIterator<*> },
        "ListIterator".takeIf { x is ListIterator<*> },
        "MutableListIterator".takeIf { x is MutableListIterator<*> },
        "IntIterator".takeIf { x is IntIterator },
        "CharIterator".takeIf { x is CharIterator },
    )
    println("$label: ${kinds.joinToString()}")
}

fun main() {
    val tasks = mutableListOf("plan", "build", "test", "ship")
    describe("list", tasks.iterator())
    describe("read-only list", listOf(1, 2).iterator())
    describe("list iterator", tasks.listIterator())
    describe("set", linkedSetOf('a').iterator())
    describe("map", linkedMapOf(1 to "one").iterator())
    describe("map keys", linkedMapOf(1 to "one").keys.iterator())
    describe("array", arrayOf("x").iterator())
    describe("int array", intArrayOf(1).iterator())
    describe("string", "kotlin".iterator())
    describe("range", (1..3).iterator())
    describe("sequence", sequenceOf(1).iterator())

    // An iterator typed as a plain `Iterator` casts to the mutable one it is.
    val plain: Iterator<String> = tasks.iterator()
    val mutable = plain as MutableIterator<String>
    mutable.next()
    mutable.remove()
    println(tasks)

    // A list iterator walks both ways, setting and adding as it goes.
    val li = (tasks.listIterator() as Any) as MutableListIterator<String>
    while (li.hasNext()) {
        val t = li.next()
        if (t == "build") li.set("BUILD") else if (t == "ship") li.add("celebrate")
    }
    val back = mutableListOf<String>()
    while (li.hasPrevious()) back += li.previous()
    println("$tasks $back")

    // Primitive iterators hand out primitives.
    val digits = intArrayOf(4, 2, 7).iterator()
    var sum = 0
    while (digits.hasNext()) sum += digits.nextInt()
    val letters = "Hé!".iterator()
    val codes = mutableListOf<Int>()
    while (letters.hasNext()) codes += letters.nextChar().code
    println("$sum $codes")
}
