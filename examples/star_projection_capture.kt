// A star-projected value passed where a type argument is inferred
// captures an unknown type, also when it comes from a nested call:
// `FlowSer(xs.first())` for `xs: List<Ser<*>>` makes a `FlowSer` of the
// captured type, in a lambda as in a plain call. Only the overload whose
// parameter is a function type takes the lambda.
import kotlin.reflect.KClass

interface Ser<T> {
    val name: String
}

class FlowSer<T>(val value: Ser<T>) : Ser<List<T>> {
    override val name: String get() = "Flow<" + value.name + ">"
}

object IntSer : Ser<Int> {
    override val name: String get() = "Int"
}

object StringSer : Ser<String> {
    override val name: String get() = "String"
}

class Builder {
    fun <T : Any> contextual(kClass: KClass<T>, serializer: Ser<T>) {
        println("serializer for ${kClass.simpleName}: ${serializer.name}")
    }

    fun <T : Any> contextual(kClass: KClass<T>, provider: (typeArgumentsSerializers: List<Ser<*>>) -> Ser<*>) {
        println("provider for ${kClass.simpleName}: ${provider(listOf(IntSer, StringSer)).name}")
    }
}

fun direct(x: Ser<*>): Ser<*> = FlowSer(x)

fun fromList(xs: List<Ser<*>>): Ser<*> = FlowSer(xs.first())

fun fromLast(xs: List<Ser<*>>): Ser<*> = FlowSer(xs.last())

fun main() {
    val b = Builder()
    b.contextual(List::class) { elementSerializers -> FlowSer(elementSerializers.first()) }
    b.contextual(Set::class) { elementSerializers -> FlowSer(FlowSer(elementSerializers.last())) }
    b.contextual(Int::class, IntSer)
    println(direct(IntSer).name)
    println(fromList(listOf(StringSer, IntSer)).name)
    println(fromLast(listOf(StringSer, IntSer)).name)
}
