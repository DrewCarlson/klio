// A nested class and a top-level class may share a simple name. Each one's
// properties belong to its own type, and a read of the top-level class's
// inherited property must resolve against the type that class declares — not
// against the nested namesake's.
package demo

class Wrong {
    fun tag(): String = "wrong"
}

class Right {
    fun tag(): String = "right"
}

open class Base {
    val p: Right = Right()
}

class Holder : Base()

class Unrelated {
    class Holder {
        val p = Wrong()
    }

    fun nested(): String = Holder().p.tag()
}

// The same shape one level deeper, and through a companion.
class Outer {
    class Config {
        val backing = Wrong()
    }
}

class Config {
    val backing = Right()

    companion object {
        val shared = Right()
    }
}

fun main() {
    println(Holder().p.tag())
    println(Unrelated().nested())
    println(Config().backing.tag())
    println(Outer.Config().backing.tag())
    println(Config.shared.tag())
}
