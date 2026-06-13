// An empty container typed by its binding annotation (no creation-site type
// argument) carries that element head for receiver proofs: inside `with`,
// the `List<String>.describe()` / `Map<String,Int>.describe()` extension
// wins over the enclosing class's same-named member, exactly as kotlinc
// binds the extension. The lowering reads the binding annotation
// (`val xs: List<String>`) and stamps the element head the runtime value
// could not otherwise carry.
fun List<String>.describe(): String = "ext List<String>"
fun Map<String, Int>.describe(): String = "ext Map<String, Int>"

class Outer {
    fun describe(): String = "outer member"
    fun probeList(): String {
        val xs: List<String> = emptyList()
        return with(xs) { describe() }
    }
    fun probeMap(): String {
        val m: Map<String, Int> = emptyMap()
        return with(m) { describe() }
    }
}

fun main() {
    println(Outer().probeList())
    println(Outer().probeMap())
}
