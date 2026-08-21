import kotlin.reflect.KProperty

class Store {
    val map = HashMap<String, Any?>()
}

class Delegate(val key: String) {
    operator fun getValue(thisRef: Holder, p: KProperty<*>): String? = thisRef.store.map[key] as String?
    operator fun setValue(thisRef: Holder, p: KProperty<*>, v: String?) { thisRef.store.map[key] = v }
}

class Holder(val store: Store = Store()) {
    var tz: String? by Delegate("tz")
    var plain: String? = null
}

fun main() {
    val h = Holder()
    h.tz = "America/New_York".substring(0)
    h.plain = "Europe/Berlin".substring(0)
    println("delegated=" + h.tz + " plain=" + h.plain)
    val h2 = Holder()
    h2.tz = "X" + "Y"
    println("second=" + h2.tz)
}
