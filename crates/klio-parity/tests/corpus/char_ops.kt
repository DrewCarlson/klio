fun main() {
    println('A'.digitToInt(16))
    println('f'.digitToInt(16))
    println('z'.digitToInt(36))
    println('7'.digitToInt())
    println('9'.digitToIntOrNull(8))
    println('g'.digitToIntOrNull(16))

    println('ß'.uppercaseChar())
    println('ß'.uppercase())
    println('A'.lowercaseChar())
    println('a'.uppercaseChar())

    var c = 'a'
    c++
    println(c)
    c--
    c--
    println(c)
    println('m' + 1)
    println('z' - 'a')

    println('a'.isHighSurrogate())
    println("hello".commonPrefixWith("help"))

    for (ch in 'a'..'e') print(ch)
    println()
}
