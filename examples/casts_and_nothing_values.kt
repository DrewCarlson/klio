// An unchecked cast to a type parameter checks what the JVM checks: a null
// cast to a `T` whose bounds admit no null (`T : Any`, `T : Number`, or a
// chain ending in one) throws `NullPointerException`, one to `T?` or to an
// unbounded `T` passes. A call whose generic result the caller fixed as
// `Nothing` throws `KotlinNothingValueException` if it returns at all, here
// through a `Context<in T>` parameter given a `Context<out Any>`.
@Suppress("UNCHECKED_CAST")
fun <T : Any> nonNull(x: Any?) = x as T

@Suppress("UNCHECKED_CAST")
fun <T : Number> number(x: Any?) = x as T

@Suppress("UNCHECKED_CAST")
fun <U : Any, T : U> chained(x: Any?) = x as T

@Suppress("UNCHECKED_CAST")
fun <T> plain(x: Any?) = x as T

@Suppress("UNCHECKED_CAST")
fun <T : Any> nullable(x: Any?) = x as T?

@Suppress("UNCHECKED_CAST")
fun <T> something(): T = Any() as T

class Context<T>

fun <T> Any.decodeIn(typeFrom: Context<in T>): T = something()

fun probe(name: String, f: () -> Any?) {
    try {
        println("$name -> ${f()}")
    } catch (e: RuntimeException) {
        println("$name threw ${e::class.simpleName}")
    }
}

fun main() {
    probe("T : Any") { nonNull<String>(null) }
    probe("T : Number") { number<Int>(null) }
    probe("T : U, U : Any") { chained<Any, String>(null) }
    probe("unbounded T") { plain<String>(null) }
    probe("T?") { nullable<String>(null) }
    probe("a value") { nonNull<String>("kept") }
    probe("Number given a String") { number<Int>("text") }

    probe("something<Nothing>()") { something<Nothing>() }
    val ctx: Context<out Any> = Context<Any>()
    probe("decodeIn(Context<out Any>)") { "s".decodeIn(ctx) }
    probe("through a safe call") {
        val receiver: Any? = "s"
        receiver?.decodeIn(ctx)
    }
}
