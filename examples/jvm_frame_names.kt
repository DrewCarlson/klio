// A stack frame names what the JVM runs: the class and method kotlinc
// compiles each function to, and the file and line. A top-level function
// runs in its file's facade (`Jvm_frame_namesKt`), a member in its class,
// a companion's in `Box$Companion`, a property's accessor in `getProp`, a
// lambda in `main$lambda$0` (numbered in source order within the function,
// a nested one after its own), a local function in `outer$local`, and an
// object's, a companion's, an enum's or a file's initialization in the
// class's `<clinit>`.
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
