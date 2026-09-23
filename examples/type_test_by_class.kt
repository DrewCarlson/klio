// `x is T` asks whether the value's class is at or below `T`, which is an
// identity question once the site names the class. The cases below are the
// ones that decide whether it can be asked that way: an interface reached
// through a chain, a sealed hierarchy, a nullable test that admits null, an
// erased generic argument, and a value that carries no user class at all.
//
// Run with: klio run examples/type_test_by_class.kt

interface Shape
interface Drawable

abstract class Figure : Shape

class Circle(val r: Int) : Figure(), Drawable
class Square(val side: Int) : Figure()

sealed interface Json
class JsonNum(val n: Int) : Json
class JsonText(val s: String) : Json

object JsonNull : Json

fun describe(a: Any?): String = when (a) {
    // Null first: `is` is false for null, and `is T?` is true.
    null -> "null"
    is Circle -> "circle:${a.r}"
    is Square -> "square:${a.side}"
    // Reached through `Circle : Figure : Shape`, never declared directly.
    is Shape -> "other shape"
    is Int -> "int:$a"
    is String -> "text:$a"
    is List<*> -> "list:${a.size}"
    else -> "unknown"
}

fun render(j: Json): String = when (j) {
    is JsonNum -> "n${j.n}"
    is JsonText -> "t${j.s}"
    JsonNull -> "null"
}

fun main() {
    println(describe(Circle(2)))
    println(describe(Square(3)))
    println(describe(object : Figure() {}))
    println(describe(7))
    println(describe("hi"))
    println(describe(listOf(1, 2)))
    println(describe(null))
    println(describe(3.5))

    // An interface a class reaches only through its supertypes.
    val c: Any = Circle(1)
    println("drawable=${c is Drawable} shape=${c is Shape}")
    val s: Any = Square(1)
    println("drawable=${s is Drawable} shape=${s is Shape}")

    // Nullable admits null; the plain test does not.
    val n: Any? = null
    println("plain=${n is Shape} nullable=${n is Shape?}")

    println(render(JsonNum(4)))
    println(render(JsonText("x")))
    println(render(JsonNull))

    // Negation, and a test that is false for every branch above.
    val f: Any = Figure::class
    println("notshape=${f !is Shape}")

    // `as` asks the same question first. The implicit root answers for every
    // value, a safe cast yields null instead of throwing, and a failed
    // unchecked cast raises.
    val up = c as Shape
    println("up=${up is Circle}")
    println("any=${(c as Any) === c}")
    println("safe=${(s as? Drawable)}")
    println(try {
        @Suppress("UNUSED_EXPRESSION")
        s as Drawable
        "no throw"
    } catch (e: ClassCastException) {
        "cce"
    })
}
