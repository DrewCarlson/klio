fun describe(v: Any): String {
    val s = v as? String
    return if (s != null) "string of length ${s.length}" else "not a string"
}

fun main() {
    val a: Any = "hello"
    val b: Any = 42

    println(a as String)
    println(describe(a))
    println(describe(b))

    val chain: Any = "stack"
    println(chain as Any as String)
}
