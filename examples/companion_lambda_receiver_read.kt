abstract class Ctx {
    abstract val call: String
}

class LiveCtx : Ctx() {
    override val call: String = "ctx-call"
}

class Pipe {
    val blocks = mutableListOf<Ctx.() -> Unit>()

    fun intercept(block: Ctx.() -> Unit) {
        blocks.add(block)
    }

    fun run() {
        for (b in blocks) LiveCtx().b()
    }
}

abstract class Response(val call: String) {
    companion object {
        fun setup(pipe: Pipe) {
            pipe.intercept {
                println("seen " + call)
            }
        }
    }
}

fun main() {
    val p = Pipe()
    Response.setup(p)
    p.run()
}
