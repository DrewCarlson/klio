// A local class's `init { }` blocks run at construction — in declaration
// order interleaved with property initializers — and observe the enclosing
// function's captured vars through their shared cells: `count++` inside a
// local class's init is visible to the declaring scope.
package examples.localinit

fun main() {
    var count = 0
    class Tracked(val label: String) {
        init {
            count++
            println("init#1 $label count=$count")
        }
        val doubled = count * 2
        init {
            println("init#2 doubled=$doubled")
        }
        fun bump() {
            count++
        }
    }
    val t = Tracked("a")
    Tracked("b")
    t.bump()
    println("outer count=$count")
}
