@Target(
    AnnotationTarget.FUNCTION,
    AnnotationTarget.TYPE,
    AnnotationTarget.TYPE_PARAMETER,
    AnnotationTarget.PROPERTY_GETTER,
)
annotation class Composable

class Scope {
    fun emit(label: String) {
        println("emit:$label")
    }
}

typealias Content = @Composable () -> Unit

fun runContent(content: @Composable () -> Unit): @Composable () -> Unit {
    content()
    return content
}

fun runScoped(content: @Composable Scope.() -> Unit) {
    Scope().content()
}

fun runMaybe(content: (@Composable () -> Unit)?) {
    content?.invoke()
}

val provided: Int
    @Composable get() = 7

interface Holder {
    val value: Int
        @Composable get
}

class HolderImpl(override val value: Int) : Holder

class Pair2(val first: Int, val second: Int) {
    constructor(both: Int) : this(first = both, second = both)
}

fun castThrough(block: Any): Int {
    val typed =
        block
            as () -> Int
    return typed()
}

fun main() {
    val c: Content = { println("body") }
    runContent(c)
    runScoped { emit("scoped") }
    runMaybe(null)
    runMaybe { println("present") }

    val list: List<@Composable () -> Unit> = listOf({ println("first") }, { println("second") })
    for (f in list) f()

    val annotated = @Composable { println("annotated-lambda") }
    runContent(annotated)

    println(provided)
    println(HolderImpl(11).value)
    println(Pair2(4).first + Pair2(4).second)
    println(castThrough({ 99 }))

    @Suppress("UNUSED") val suppressed = (provided as Int)
    println(suppressed)
}
