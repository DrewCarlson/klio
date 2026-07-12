// Vararg binding across dispatch forms: a raw element never lands in a
// non-final vararg slot positionally (the vararg absorbs the middle args,
// trailing defaulted params keep their defaults), a named trailing arg
// binds its parameter past the vararg, a List overload still wins for a
// List argument, and a final-vararg param's static type inside the body
// is the materialized Array (so `path.map { it.length }` maps elements).

class Box
fun Box.add(segments: List<String>, flag: Boolean = false) { println("LIST $segments flag=$flag") }
fun Box.add(vararg components: String, flag: Boolean = false) { println("VARARG ${components.toList()} flag=$flag") }
fun go(vararg path: String) { println("GO ${path.map { it.length }}") }

fun main() {
    Box().add("hello")
    Box().add("a", "b")
    Box().add(listOf("l"))
    Box().add("path/", "/abc", flag = true)
    go("hello/world")
}
