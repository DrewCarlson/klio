import kotlin.reflect.KProperty

class Slot<T>(private var stored: T) {
    operator fun getValue(thisRef: Any?, property: KProperty<*>): T = stored
    operator fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
        stored = value
    }
}

abstract class Base {
    private var slot: List<String>? by Slot(null)
    fun isNull(): Boolean = slot == null
    fun current(): List<String>? = slot
    fun fill() {
        if (slot == null) {
            slot = mutableListOf("x")
        }
    }
    fun replace(v: List<String>) {
        slot = v
    }
}

class Sub : Base()

fun main() {
    val s = Sub()
    println(s.isNull())
    s.fill()
    println(s.isNull())
    println(s.current())
    s.replace(listOf("a", "b", "c"))
    println(s.current())
    println(s.current()!!.size)
}
