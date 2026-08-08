// A class-named receiver whose member names a nested constructible class is
// a constructor call (`Outer.Builder(7)`), emitted as a statically bound
// NewInstance rather than a member walk on the companion value — including
// inside a property getter where the receiver name is otherwise untyped.
class Outer(val tag: String) {
    class Builder(val n: Int) {
        fun build(): Outer = Outer("built:$n")
    }

    companion object {
        val marker = "companion-lives"
    }
}

class Wrap {
    val fresh: Outer.Builder
        get() = Outer.Builder(7)
}

fun main() {
    println(Wrap().fresh.build().tag)
    println(Outer.Builder(3).n)
    println(Outer.marker)
}
