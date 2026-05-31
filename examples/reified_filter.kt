sealed class Event
class Click(val x: Int) : Event()
class Key(val code: Int) : Event()

inline fun <reified T> List<*>.countOf(): Int = filterIsInstance<T>().size

fun main() {
    val events: List<Event> = listOf(Click(1), Key(65), Click(2), Key(66), Click(3))

    println(events.filterIsInstance<Click>().map { it.x })
    println(events.filterIsInstance<Key>().map { it.code })
    println(events.filterIsInstance<Event>().size)

    val any: List<Any> = listOf(1, "a", 2.0, 3, "b", 4L)
    println(any.filterIsInstance<Int>())
    println(any.filterIsInstance<String>())
    println(any.filterIsInstance<Number>())

    // A user-defined reified inline extension composes with the
    // stdlib one.
    println(events.countOf<Click>())
    println(events.countOf<Key>())
}
