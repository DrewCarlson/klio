fun main() {
    val sb = StringBuilder()
    for (i in 1..5) {
        if (sb.isNotEmpty()) sb.append(", ")
        sb.append(i * i)
    }
    println(sb.toString())
    println(sb.length)
    sb.insert(0, "squares: ")
    println(sb.toString())
    sb.reverse()
    println(sb.toString())
    val log = StringBuilder()
    log.appendLine("step 1")
    log.appendLine("step 2")
    log.append("done")
    println(log.toString())
}
