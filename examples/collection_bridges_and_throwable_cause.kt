// A class implementing a collection or map interface with a narrower
// parameter type than the interface's erased signature never sees an
// argument outside that type: `get`/`remove` on such a map answer null,
// `containsKey`/`containsValue`/`contains` answer false and `indexOf`
// answers -1, exactly as the JVM's type-checking bridges do. A
// `Throwable` built from a cause alone renders the cause as its message.
object NotEmptyMap : Map<Any, Any> {
    override fun containsKey(key: Any): Boolean = true
    override fun containsValue(value: Any): Boolean = true
    override fun get(key: Any): Any? = "v"
    override val size: Int get() = 1
    override fun isEmpty(): Boolean = false
    override val entries: Set<Map.Entry<Any, Any>> get() = emptySet()
    override val keys: Set<Any> get() = emptySet()
    override val values: Collection<Any> get() = emptyList()
}

object Everything : Collection<String> {
    override val size: Int get() = 1
    override fun isEmpty(): Boolean = false
    override fun iterator(): Iterator<String> = listOf("x").iterator()
    override fun containsAll(elements: Collection<String>): Boolean = true
    override fun contains(element: String): Boolean = true
}

class CustomException : Throwable {
    constructor(message: String?, cause: Throwable?) : super(message, cause)
    constructor(cause: Throwable?) : super(cause)
}

fun main() {
    val m = NotEmptyMap as Map<Any?, Any?>
    println(m.get(null))
    println(m.containsKey(null))
    println(m.get("k"))
    println(m.containsKey("k"))
    val c = Everything as Collection<Any?>
    println(c.contains(1))
    println(c.contains("y"))
    val t = Throwable(Throwable("inner"))
    println(t.message == t.cause.toString())
    println(t.cause?.message)
    val u = CustomException(Throwable("deep"))
    println(u.message == u.cause.toString())
    println(u.cause?.message)
    println(CustomException("m", null).message)
}
