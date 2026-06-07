class EventBus {
    private val handlers = mutableMapOf<String, MutableList<(Int) -> Unit>>()
    fun on(name: String, h: (Int) -> Unit) {
        handlers.getOrPut(name) { mutableListOf() }.add(h)
    }
    fun emit(name: String, payload: Int) {
        val hs = handlers[name] ?: return
        for (h in hs) h(payload)
    }
}

fun main() {
    val bus = EventBus()
    var counter = 0
    bus.on("tick") { counter += it }
    bus.on("tick") { counter += it * 2 }
    bus.on("damage") { counter -= it }
    var i = 0
    while (i < 5000) {
        bus.emit(if (i % 4 == 0) "damage" else "tick", i % 7)
        i += 1
    }
    println(counter)
}
