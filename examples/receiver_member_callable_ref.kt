class Ctx {
    fun proceed(): String = "proceeded"
}

fun useRef(r: () -> String) {
    println("ref -> " + r())
}

fun withCtx(block: Ctx.() -> Unit) {
    Ctx().block()
}

fun main() {
    withCtx {
        useRef(::proceed)
    }
    val c2 = Ctx()
    useRef(c2::proceed)
}
