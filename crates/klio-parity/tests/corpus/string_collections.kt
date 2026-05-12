fun main() {
    val s = "hello"
    println(s.toList())
    println(s.split(","))
    println("a,b,c,d".split(","))
    println("a,,b".split(","))
    println("abcdef".chunked(2))
    println("abcdef".windowed(3))
    println("abcdef".windowed(3, 2))
}
