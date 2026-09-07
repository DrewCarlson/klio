// Callable reference forms: an inner class constructor reference takes the
// outer instance as its receiver or first argument; `::Array` and
// `::IntArray` forward to the array constructors; `::arrayOf` against a slot
// taking the array itself passes it through; `E::valueOf` takes no receiver;
// `(::topLevel)()` reads through the getter; an extension property reference
// reads the property bound or unbound; `value::localExt` binds its receiver;
// and a receiver-less `::name` inside a class binds `this` to a member, an
// extension or an extension property of the class.
var log = ""

class Outer(val tag: String) {
    inner class Inner(val n: Int) {
        override fun toString() = "$tag#$n"
    }
}

enum class Color { RED, GREEN }

var counter: Int = 0
    get() {
        log += "g"
        return field
    }

val Outer.suffix: String get() = "$tag!"

class Host(val name: String) {
    fun member() = "m:$name"
    fun test(): String {
        val m = ::member
        val d = ::describe
        val g = ::greeting
        return "${m()}|${d()}|${g()}"
    }
}

fun Host.describe() = "d:$name"
val Host.greeting: String get() = "hello $name"

fun build(f: (Int, (Int) -> String) -> Array<String>): Array<String> = f(2) { "e$it" }
fun useArray(f: (Array<String>) -> Array<String>) = f(arrayOf("a", "b"))

fun main() {
    val make: Outer.(Int) -> Outer.Inner = Outer::Inner
    println(Outer("o").make(1))
    val make2 = Outer::Inner
    println(make2(Outer("p"), 2))
    println(build(::Array).joinToString(","))
    val ints: (Int) -> IntArray = ::IntArray
    println(ints(3).size)
    println(useArray(::arrayOf).size)
    val chars: (CharArray) -> CharArray = ::charArrayOf
    println(chars(charArrayOf('o', 'k')).concatToString())
    val valueOf = Color::valueOf
    println(valueOf("GREEN"))
    println((::counter)())
    println(log)
    val o = Outer("z")
    val bound = o::suffix
    println(bound())
    println((Outer::suffix)(o))
    val x = 10
    fun Outer.scaled(k: Int) = tag.length * k * x
    val scaled = o::scaled
    println(scaled(3))
    println(Host("h").test())
}
