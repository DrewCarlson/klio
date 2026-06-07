// A member function whose parameter defaults to a function reference (`::fn`)
// must call that function when the parameter is invoked. The default-arg thunk
// for a method is lowered before top-level functions are registered, so `::fn`
// records a property reference rather than a direct global load; invoking such
// a reference now calls the named function.
fun shout(s: String): String = s.uppercase() + "!"
fun wrap(s: String): String = "<$s>"

class Greeter(private val name: String) {
    fun render(f: (String) -> String = ::shout): String = f(name)
    fun renderInvoke(f: (String) -> String = ::wrap): String = f.invoke(name)
    fun renderLambdaDefault(f: (String) -> String = { "[$it]" }): String = f(name)
}

fun main() {
    val g = Greeter("ann")
    println(g.render())
    println(g.render(::wrap))
    println(g.renderInvoke())
    println(g.renderLambdaDefault())
}
