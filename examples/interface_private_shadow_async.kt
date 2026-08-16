// An interface's private accessor property is the one its own default
// member reads, even when a subclass declares a same-named private stored
// field; the async started inside the default member must resolve and
// complete rather than parking on the shadowed name.
import kotlinx.coroutines.*

interface Gate {
    val name: String

    private val closed: Boolean
        get() = name.isEmpty()

    suspend fun status(): String {
        return coroutineScope {
            val d = async {
                if (closed) "closed" else "open"
            }
            d.await()
        }
    }
}

abstract class GateBase : Gate {
    private val closed = "ATOM"
}

class DoorGate : GateBase() {
    override val name = "e"
}

suspend fun main() {
    println(DoorGate().status())
}
