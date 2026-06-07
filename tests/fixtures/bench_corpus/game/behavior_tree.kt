sealed class Node {
    abstract fun tick(state: State): Boolean
}

class State(var energy: Int, var pos: Int, var target: Int)

class Cond(val pred: (State) -> Boolean) : Node() {
    override fun tick(state: State) = pred(state)
}

class Action(val act: (State) -> Boolean) : Node() {
    override fun tick(state: State) = act(state)
}

class Seq(val children: List<Node>) : Node() {
    override fun tick(state: State): Boolean {
        for (c in children) if (!c.tick(state)) return false
        return true
    }
}

class Sel(val children: List<Node>) : Node() {
    override fun tick(state: State): Boolean {
        for (c in children) if (c.tick(state)) return true
        return false
    }
}

fun buildTree(): Node = Sel(listOf(
    Seq(listOf(
        Cond { it.energy > 0 },
        Action { s -> s.pos += if (s.pos < s.target) 1 else -1; s.energy -= 1; true },
    )),
    Action { s -> s.energy = 10; true },
))

fun main() {
    val tree = buildTree()
    val state = State(10, 0, 50)
    var ticks = 0
    while (ticks < 500) { tree.tick(state); ticks += 1 }
    println("${state.pos},${state.energy}")
}
