fun main() {
    val s = "Hello" + ", " + "World"
    println(s)

    var b = ""
    b += "alpha"
    b += "-"
    b += "beta"
    println(b)

    // String + non-String coerces via toString
    val mix = "n=" + 42 + ", b=" + true
    println(mix)
}
