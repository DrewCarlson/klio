// A top-level function with the same name as a class is a factory overload of
// the constructor. When the factory and the constructor have the same arity,
// the call is disambiguated by argument type: `Box(5)` constructs (Int), while
// `Box("hi")` calls the factory (String). Order of declaration does not matter.

class Box(val v: Int)
fun Box(s: String): Box = Box(s.length)

fun Tag(n: Int): Tag = Tag(n.toString())   // factory declared before the class
class Tag(val label: String)

class Pt(val x: Int, val y: Int)
fun Pt(s: String): Pt = Pt(s.length, 0)     // different arity from the ctor

class Token(val x: Int)
fun Token(x: Any): String = "factory"

fun main() {
    println(Box(5).v)          // ctor -> 5
    println(Box("hello").v)    // factory -> "hello".length = 5
    println(Tag(7).label)      // factory -> "7"
    println(Tag("x").label)    // ctor   -> "x"
    println(Pt(1, 2).x)        // ctor (arity 2) -> 1
    println(Pt("abc").x)       // factory (arity 1) -> "abc".length = 3
    val token = Token(1)       // ctor(Int) outranks factory(Any)
    println(if (token is Token) "ctor" else token)
}
