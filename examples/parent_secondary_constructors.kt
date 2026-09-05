// A subclass header picks the parent constructor its arguments fit, as a
// direct instantiation would: `A(5)` reaches `constructor(n: Int)` even
// though the primary also takes one parameter, `A()` a zero-argument one,
// and `A(y = 44)` binds by name with the other defaults filled in. The
// chosen constructor delegates with `this(…)` and its body runs after the
// parent's initializers, before the subclass's. An enum's entries may
// override its `open` members through their bodies.
var trace = ""

open class A(val p: String) {
    var q = ""
    init {
        trace += "A-init;"
    }
    constructor() : this("d") {
        q = "e"
        trace += "A-empty;"
    }
    constructor(n: Int) : this("n$n") {
        q = "i"
    }
    constructor(x: Int = 11, y: Int = 22, z: Int = 33) : this("$x$y$z") {
        q = "named"
    }
}

class B : A() {
    init {
        trace += "B-init;"
    }
}

class C : A(5)
class D : A(y = 44)
class E(x: Int) : A(x + 1)

open class Base {
    val label: String
    constructor(s: String = "default") {
        label = s
    }
    constructor(s: String = "default", n: Int) {
        label = "$s#$n"
    }
}

class Named : Base(n = 3)

enum class Op(val symbol: String) {
    PLUS("+") {
        override fun apply(a: Int, b: Int) = a + b
    },
    TIMES("*") {
        override fun apply(a: Int, b: Int) = a * b
        override fun describe() = super.describe() + " (commutative)"
    };

    abstract fun apply(a: Int, b: Int): Int
    open fun describe() = "$name $symbol"
}

fun main() {
    val b = B()
    println("${b.p} ${b.q}")
    println(trace)
    println("${C().p} ${C().q}")
    println("${D().p} ${D().q}")
    println("${E(1).p} ${E(1).q}")
    println(Base().label)
    println(Named().label)
    val op: Op = Op.TIMES
    println(op.apply(6, 7))
    println(op.describe())
    println(Op.PLUS.describe())
}
