// A generic `provideDelegate` takes its type argument from the property's
// declared type: `val text: String by registry` makes `T` a `String`, so
// the delegate it returns gives a `String`.
import kotlin.properties.ReadOnlyProperty
import kotlin.reflect.KProperty

class Registry(val values: Map<String, Any>) {
    inline operator fun <reified T : Any> provideDelegate(thisRef: Any?, prop: KProperty<*>): ReadOnlyProperty<Any?, T> {
        val name = T::class.simpleName!!
        println("provideDelegate for ${prop.name}: $name")
        return ReadOnlyProperty { _, _ -> values.getValue(name) as T }
    }
}

class Settings(registry: Registry) {
    val title: String by registry
    val count: Int by registry
}

fun main() {
    val registry = Registry(mapOf("String" to "a string", "Int" to 42))
    val text: String by registry
    val number: Int by registry
    println("$text $number")
    val settings = Settings(registry)
    println("${settings.title} ${settings.count + 1}")
}
