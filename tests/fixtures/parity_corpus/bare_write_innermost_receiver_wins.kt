// When several implicit receivers own a member of the written name, the
// innermost receiver takes the bare-name write.
class A {
    var tag: String = "a-init"
}

class B {
    var tag: String = "b-init"
}

fun main() {
    val a = A()
    val b = B()
    with(a) {
        with(b) {
            tag = "written"
        }
    }
    println(a.tag)
    println(b.tag)
}
