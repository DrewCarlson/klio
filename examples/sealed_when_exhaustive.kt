// M23: typeck enforces sealed-`when` exhaustiveness. This program omits
// the `else` branch — every concrete subclass is matched explicitly.

sealed class Event
class Click(val x: Int, val y: Int): Event()
class Key(val code: Int): Event()
class Resize(val w: Int, val h: Int): Event()

fun describe(e: Event): String = when (e) {
    is Click -> "click@(${e.x},${e.y})"
    is Key -> "key(${e.code})"
    is Resize -> "resize(${e.w}x${e.h})"
}

fun main() {
    val events: List<Event> = listOf(Click(1, 2), Key(65), Resize(800, 600))
    for (e in events) println(describe(e))
}
