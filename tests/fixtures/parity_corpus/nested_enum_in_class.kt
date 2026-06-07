class TrafficLight {
    enum class State { RED, YELLOW, GREEN }

    var state: State = State.RED
        private set

    fun next() {
        state = when (state) {
            State.RED -> State.GREEN
            State.GREEN -> State.YELLOW
            State.YELLOW -> State.RED
        }
    }
}

fun main() {
    val t = TrafficLight()
    for (i in 1..5) {
        println(t.state)
        t.next()
    }
}
