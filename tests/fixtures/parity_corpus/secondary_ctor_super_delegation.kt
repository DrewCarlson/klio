open class Base(val tag: String) {
    fun show(): String = "Base(tag=$tag)"
}

class Child : Base {
    var extra: Int = 0

    constructor(tag: String, extra: Int) : super(tag) {
        this.extra = extra
    }
}

fun main() {
    val c = Child("hello", 42)
    println(c.show())
    println("extra=${c.extra}")
}
