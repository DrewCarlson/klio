// A cast whose target is an erased function type (`as (Int) -> Int` lowers
// with the `<function>` head) passes leniently for a callable value — the
// erased-target leniency is part of Cast semantics and must hold on the
// fused walker exactly as it does framed.
class Registry {
    private val entries = HashMap<String, Any>()
    fun put(k: String, v: Any) { entries[k] = v }
    fun applyTo(k: String, x: Int): Int {
        val f = entries[k] as (Int) -> Int
        return f(x)
    }
}
fun main() {
    val r = Registry()
    r.put("double", { n: Int -> n * 2 })
    println(r.applyTo("double", 21))
    val any: Any = { n: Int -> n + 5 }
    val g = any as (Int) -> Int
    println(g(10))
}
