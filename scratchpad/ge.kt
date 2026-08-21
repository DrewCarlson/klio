import kotlin.reflect.KMutableProperty1

class Contents(var tz: String? = null)

class Accessor<O, F>(val property: KMutableProperty1<O, F?>) {
    val name: String = property.name
    fun trySet(c: O, v: F): F? {
        val old = property.get(c)
        return if (old === null) { property.set(c, v); null } else old
    }
}

// top-level val, built during module init — as kotlinx-datetime does
val tzField = Accessor(Contents::tz)

fun churn(n: Int): Int { var a = 0; for (i in 0 until n) { val s = "q" + i; a += s.length }; return a }

fun main() {
    val c = Contents()
    println("conflict=" + tzField.trySet(c, "America/New_York") + " readback=" + c.tz + " viaProp=" + tzField.property.get(c))
    churn(20)
    val c2 = Contents()
    println("after churn conflict=" + tzField.trySet(c2, "Asia/Tokyo") + " readback=" + c2.tz)
}
