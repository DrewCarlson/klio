open class Base {
    val greeting: String by lazy { "hello-from-base" }
}

class Sub : Base()

class WrappingSub : Base() {
    fun show(): String = greeting
}

fun main() {
    val s = Sub()
    println(s.greeting)
    println(s.greeting)

    val b: Base = s
    println(b.greeting)

    val w = WrappingSub()
    println(w.show())
    println(w.greeting)
}
