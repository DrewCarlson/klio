fun main() {
    println("a,b;c,d".split(",", ";"))
    println("a,b,c,d".split(",", limit = 2))
    println("1-2_3-4".split("-", "_"))
    println("axbxc".split("x"))
    println("a.b.c".split("."))
    println("one two  three".split(" "))
    println("HELLOxworld".split("X", ignoreCase = true))

    println("**hi**".trim('*'))
    println("xxabcxx".trimStart('x'))
    println("xxabcxx".trimEnd('x'))
    println("  spaced  ".trim())
    println("123abc456".trim { it.isDigit() })
    println("--a-b--".trim('-'))
}
