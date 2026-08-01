// A property getter's expression body takes the property's declared type
// as its expected type: the returned parameter-lambda keeps its parameter
// shape, so invoking it through a receiver-function type feeds the
// receiver into the parameter instead of leaving it unbound.
class Holder {
    val f: (String) -> String
        get() = { "got:" + it }
}
fun call(block: String.() -> String): String = "x".block()
fun main() {
    println(call(Holder().f))
}
