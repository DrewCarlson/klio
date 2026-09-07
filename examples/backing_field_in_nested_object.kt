// `field` inside an accessor names the backing field of the property whose
// accessor it is, even from an anonymous object declared in the accessor
// body: for a top-level property that is the file's backing slot, for a
// member property the enclosing instance's.
abstract class Your {
    abstract val your: String
    fun foo() = your
}

val top: String = "O"
    get() = object : Your() {
        override val your = field
    }.foo() + "K"

class Holder {
    val inner: String = "in"
        get() = object : Your() {
            override val your = field + "ner"
        }.foo()
}

fun main() {
    println(top)
    println(Holder().inner)
}
