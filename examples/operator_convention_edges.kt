// Operator convention edges: `null + x` is `String?.plus`, a `<` on nullable
// or array operands resolves to the program's `compareTo` extension, an
// indexed assignment binds its value to the LAST parameter of `set` with
// the parameters in between taking their defaults, a vararg index
// parameter absorbs every index, and a delegate's `getValue`/`setValue`
// may be a member extension of the property's owner.
import kotlin.reflect.KProperty

private operator fun Long?.compareTo(other: Long?): Int = ((this ?: 0L) - (other ?: 0L)).toInt()
private operator fun Array<Int>.compareTo(other: Array<Int>): Int = size - other.size

class Table {
    var log = ""
    operator fun get(name: String, width: Int = 8) = "$name/$width"
    operator fun set(name: String, sep: String = ":", value: String) {
        log = name + sep + value
    }
}

object Grid {
    var cell = 0
    var seen = 0
    operator fun get(vararg idx: Int): Int {
        for (i in idx) seen += i
        return cell
    }
    operator fun set(vararg idx: Int, value: Int) {
        for (i in idx) seen += i
        cell = value
    }
}

class Box {
    operator fun Int.getValue(thisRef: Any?, p: KProperty<*>): Int = this * 2
    operator fun Int.setValue(thisRef: Any?, p: KProperty<*>, v: Int) { stored = v }
    var stored = 0
    var twice: Int by 21
}

fun main() {
    println(null + "x")
    val s: String? = null
    println(s + null)
    val a: Long? = null
    val b: Long? = 42L
    println(a < b)
    println(arrayOf(1, 2, 3) >= arrayOf(1))
    val t = Table()
    t["k"] += "v"
    println(t.log)
    val old = Grid[1, 2, 3]++
    println("$old ${Grid.cell} ${Grid.seen}")
    val box = Box()
    println(box.twice)
    box.twice = 5
    println(box.stored)
}
