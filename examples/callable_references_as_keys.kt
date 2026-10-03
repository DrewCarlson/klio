// Callable references as map and set keys: a reference equals another to the
// same declaration over the same receiver and hashes as it compares, so a
// `HashMap` finds it whatever expression made it. A delegate keyed by the
// `KProperty` it is handed finds its own entry again on the next access.
import kotlin.reflect.KProperty

class Holder {
    var x = 1
    fun bar() = 2
}

object Settings {
    var y = 2
}

var top = 3

fun foo() = 1

object Store {
    private val values = mutableMapOf<Pair<Any?, KProperty<*>>, String?>()
    operator fun getValue(thisRef: Any?, property: KProperty<*>): String? = values[thisRef to property]
    operator fun setValue(thisRef: Any?, property: KProperty<*>, value: String?) {
        values[thisRef to property] = value
    }
}

object Profile {
    var name: String? by Store
    var city: String? by Store
}

fun main() {
    val h = Holder()
    val byRef = mutableMapOf<Any, String>()
    byRef[h::x] = "bound property"
    byRef[Holder::x] = "unbound property"
    byRef[Settings::y] = "object property"
    byRef[::top] = "top-level property"
    byRef[::foo] = "function"
    byRef[h::bar] = "bound function"
    println(byRef[h::x])
    println(byRef[Holder::x])
    println(byRef[Settings::y])
    println(byRef[::top])
    println(byRef[::foo])
    println(byRef[h::bar])
    println(byRef[Holder()::x])
    byRef[::foo] = "function again"
    println("${byRef.size} ${byRef[::foo]}")

    println(hashSetOf<Any>(::foo, ::foo, Holder::x, Holder::x).size)
    println(Holder::x in setOf<Any>(Holder::x))
    println((h::x to 1) in setOf<Any>(h::x to 1))

    Profile.name = "Ada"
    Profile.city = "London"
    println("${Profile.name} ${Profile.city}")
}
