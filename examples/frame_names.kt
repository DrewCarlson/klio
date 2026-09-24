// A stack frame names its function by its Kotlin qualified name, then the
// file and line. A top-level function is its package's (`main` in the root
// package), a member its class's (`Box.Companion.comp`, `Box.Nested.n`), an
// accessor `<get-prop>` or `<set-prop>`, a lambda `<anonymous>` within what
// encloses it (`main.<anonymous>`, nested ones one level each), and a local
// function its container's (`outer.local`). An object's or companion's
// initialization runs in its `<init>`, an enum's entries in
// `<init-entries>`, and a file's top-level initializers in
// `frame_names.kt.<init>`.
fun trace(): String = Throwable().stackTrace[1].toString()

fun call(f: () -> String): String = f()

val top: String get() = trace()

class Box(val v: Int) {
    val made = trace()
    fun member(): String = trace()
    fun viaLambda(): String = call { trace() }
    fun viaNested(): String = call { call { trace() } }
    val prop: String get() = trace()
    fun twoCalls(): String = call { "a" } + call { trace() }
    fun afterInline(): String {
        val xs = listOf(1).map { it + 1 }
        return call { trace() } + xs.size
    }

    companion object {
        val init = trace()
        fun comp(): String = trace()
    }

    class Nested {
        fun n(): String = trace()
    }
}

object Obj {
    val init = trace()
    fun o(): String = trace()
}

enum class E(val t: String) { A(trace()) }

class Flags {
    var isOn: Boolean = false
        get() {
            println("isOn " + trace())
            return field
        }
        set(v) {
            println("setOn " + trace())
            field = v
        }
}

val fileInit = trace()

fun withDefault(x: Int = 1): String = trace() + x

fun outer(): String {
    fun local(): String = trace()
    return local()
}

fun main(args: Array<String>) {
    val b = Box(1)
    println("made " + b.made)
    println("member " + b.member())
    println("lambda " + b.viaLambda())
    println("nested " + b.viaNested())
    println("prop " + b.prop)
    println("two " + b.twoCalls())
    println("inline " + b.afterInline())
    println("companion " + Box.init)
    println("comp " + Box.comp())
    println("class " + Box.Nested().n())
    println("object " + Obj.init)
    println("objfun " + Obj.o())
    println("enum " + E.A.t)
    println("file " + fileInit)
    println("top " + top)
    println("default " + withDefault())
    println("local " + outer())
    println("main " + call { trace() })
    val f = Flags()
    f.isOn
    f.isOn = true
}
