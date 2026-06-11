typealias Handler = (cause: String?) -> Unit

interface Reg {
    fun reg(onX: Boolean = false, immediate: Boolean = true, handler: Handler): Int
}

class Box : Reg {
    override fun reg(onX: Boolean, immediate: Boolean, handler: Handler): Int = regInternal(immediate, handler)
    private fun regInternal(immediate: Boolean, handler: Handler): Int {
        handler("go")
        return if (immediate) 1 else 2
    }
}

internal fun Reg.reg(immediate: Boolean = true, handler: (String?) -> Unit): Int {
    println("extension layer")
    return -1
}

fun main() {
    val b = Box()
    val r = b.reg(onX = true) { c -> println("handler " + c) }
    println("r=" + r)
}
