class Top
class Outer { class Nested; inner class Inner }
object Obj
enum class E { A }

class Holder {
    class Deep
}

fun main() {
    println("Top       q=" + Top::class.qualifiedName + " s=" + Top::class.simpleName)
    println("Nested    q=" + Outer.Nested::class.qualifiedName + " s=" + Outer.Nested::class.simpleName)
    println("Inner     q=" + Outer.Inner::class.qualifiedName + " s=" + Outer.Inner::class.simpleName)
    println("Obj       q=" + Obj::class.qualifiedName + " s=" + Obj::class.simpleName)
    println("E         q=" + E::class.qualifiedName + " s=" + E::class.simpleName)
    println("Deep      q=" + Holder.Deep::class.qualifiedName + " s=" + Holder.Deep::class.simpleName)
    println("String    q=" + String::class.qualifiedName + " s=" + String::class.simpleName)
}
