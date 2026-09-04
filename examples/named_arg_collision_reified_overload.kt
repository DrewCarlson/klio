// A trailing named argument that names a slot a positional argument already
// filled marks the candidate as the wrong overload: the three-argument call
// binds the three-parameter member extension, never the two-parameter reified
// helper that shares its name, even inside another reified inline wrapper.

enum class Mode { FAST, SLOW }

class Decoder<T>(val label: String)

class Box(val tag: String)

open class Base {
    inline fun <reified T : Any> Box.decode(source: String, mode: Mode): T {
        println("reified helper ${T::class.simpleName} source=$source mode=$mode")
        return decode(Decoder<T>("inferred"), source, mode)
    }

    fun <T> Box.decode(decoder: Decoder<T>, source: String, mode: Mode): T {
        println("member extension ${decoder.label} source=$source mode=$mode on ${tag}")
        if (source.startsWith("bad")) throw IllegalStateException("cannot decode $source")
        @Suppress("UNCHECKED_CAST")
        return source as T
    }
}

inline fun <reified E : Throwable> expectThrows(block: () -> Unit) {
    try {
        block()
        println("no throw")
    } catch (e: Throwable) {
        if (e is E) println("threw ${E::class.simpleName}: ${e.message}") else throw e
    }
}

class Runner : Base() {
    fun run() {
        val decoder = Decoder<String>("explicit")
        val box = Box("b1")
        for (mode in Mode.values()) {
            expectThrows<IllegalStateException> {
                box.decode(decoder, "bad input", mode = mode)
            }
            val ok: String = box.decode(decoder, "fine", mode = mode)
            println("ok=$ok")
        }
        val inferred: String = box.decode("plain", Mode.FAST)
        println("inferred=$inferred")
    }
}

fun main() {
    Runner().run()
}
