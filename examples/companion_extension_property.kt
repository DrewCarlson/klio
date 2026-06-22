enum class P { A, B; companion object }

val P.Companion.current: P get() = P.A

class C { companion object { val base = 10 } }

val C.Companion.tag: String get() = "ok"
val C.Companion.doubled: Int get() = base * 2

class Box { companion object { var raw = 0 } }

var Box.Companion.scaled: Int
    get() = raw
    set(v) { raw = v * 10 }

fun main() {
    println(P.current.name)
    println(C.tag)
    println(C.doubled)
    Box.scaled = 5
    println(Box.scaled)
}
