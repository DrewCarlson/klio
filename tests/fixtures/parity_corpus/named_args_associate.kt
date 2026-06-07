fun main() {
    val a = "x".padStart(length = 5, padChar = '-')
    println(a)
    val b = "x".padEnd(padChar = '*', length = 4)
    println(b)
    val c = "abc".repeat(n = 3)
    println(c)
    val d = "hello".replace(newValue = "L", oldValue = "l")
    println(d)
}
