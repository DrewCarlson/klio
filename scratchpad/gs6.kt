import kotlin.reflect.KMutableProperty1

class Contents { var tz: String? = null; var n: Int? = null }

class Accessor<T>(val prop: KMutableProperty1<Contents, T?>) {
    fun trySet(c: Contents, v: T): Boolean {
        val cur = prop.get(c)
        if (cur != null && cur != v) return false
        prop.set(c, v)
        return true
    }
}

val tzField = Accessor(Contents::tz)

class Fmt {
    fun write(block: Contents.() -> Unit): String { val c = Contents(); c.block(); return c.tz ?: "<none>" }
    fun read(input: String): Contents { val c = Contents(); tzField.trySet(c, input.substring(0)); return c }
}

fun main() {
    val f = Fmt()
    println("write -> " + f.write { tz = "Europe/Berlin" })
    println("read  -> " + f.read("America/New_York").tz)
}
