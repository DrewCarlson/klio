fun main() {
    val sb = StringBuilder("abcde")
    sb[1] = 'X'
    sb.set(3, 'Y')
    println(sb.toString())

    val sb2 = StringBuilder("hello world")
    for (i in 0 until sb2.length) {
        if (sb2[i] == 'o') sb2[i] = '0'
    }
    println(sb2.toString())
}
