// Function values compiled to C. A lambda whose value has to exist becomes an
// instance of a class the emitter synthesizes for that body, one field per
// capture: the collector traces it like any other instance, and a call through
// the value finds the body again by its class handle. A lambda every use of
// which is a direct call is still never materialised, so the common case
// allocates nothing.
//
// Arguments and results pass boxed through a function value, because which
// body runs is a run-time answer and two bodies of the same shape need not
// agree on machine types. A lambda's own parameters carry no declared types,
// so they come from the function type the value is expected to have.
fun apply1(f: (Int) -> Int, x: Int): Int = f(x)

fun twice(f: (Int) -> Int, x: Int): Int = f(f(x))

fun makeAdder(n: Int): (Int) -> Int = { x -> x + n }

class Pipeline(val op: (Int) -> Int) {
    fun run(x: Int): Int = op(x)
}

fun combine(f: (Int) -> Int, g: (Int) -> Int): (Int) -> Int = { x -> g(f(x)) }

fun main() {
    val double = { x: Int -> x * 2 }
    println(apply1(double, 5))
    println(twice(double, 3))

    // A closure over a value the enclosing call owned.
    val add3 = makeAdder(3)
    println(add3(10))
    println(add3(-3))

    // Stored in a field and called through it.
    println(Pipeline(double).run(7))
    println(Pipeline(add3).run(7))

    // A closure over other closures.
    val both = combine(double, add3)
    println(both(5))
}
