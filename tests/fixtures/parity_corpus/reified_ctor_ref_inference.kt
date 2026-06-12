// A reified type parameter inferred from a constructor-reference
// argument (`sleepWhile(Slot::Read)` solves `TaskType = Slot.Read` from
// the functional parameter's return type), then chained through nested
// reified inline calls (`trySuspend<TaskType>` → `resumeSlot<TaskType>`)
// where `is TaskType` checks must see the call site's resolved class.
// This is the shape of ktor's `ByteChannel` Slot wakeup protocol.
class Chan {
    sealed interface Slot {
        object Empty : Slot
        class Read(val cont: String) : Slot {
            override fun toString(): String = "Read(" + cont + ")"
        }
        class Write(val cont: String) : Slot {
            override fun toString(): String = "Write(" + cont + ")"
        }
    }

    private var slot: Slot = Slot.Empty
    private var rounds = 0

    fun runRead(): String = sleepWhile(Slot::Read) { rounds < 2 }

    fun runWrite(): String = sleepWhile(Slot::Write) { rounds < 4 }

    private inline fun <reified TaskType : Slot> sleepWhile(
        createTask: (String) -> TaskType,
        shouldSleep: () -> Boolean
    ): String {
        var log = ""
        while (shouldSleep()) {
            rounds++
            log += trySuspend<TaskType>(createTask("c" + rounds))
        }
        return log
    }

    private inline fun <reified TaskType : Slot> trySuspend(task: TaskType): String {
        val previous = slot
        slot = task
        val tag = when (previous) {
            is TaskType -> "same:" + previous
            is Slot.Read -> "read:" + previous
            is Slot.Write -> "write:" + previous
            Slot.Empty -> "empty"
        }
        return tag + resumeSlot<TaskType>() + ";"
    }

    private inline fun <reified Expected : Slot> resumeSlot(): String {
        val current = slot
        return if (current is Expected) "+hit" else "+miss"
    }
}

fun main() {
    val c = Chan()
    println(c.runRead())
    println(c.runWrite())
}
