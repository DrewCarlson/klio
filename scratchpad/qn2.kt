package my.pkg

class Top
class Outer { class Nested }
class Holder { class Deep }

fun main() {
    println("Top    q=" + Top::class.qualifiedName)
    println("Nested q=" + Outer.Nested::class.qualifiedName)
    println("Deep   q=" + Holder.Deep::class.qualifiedName)
}
