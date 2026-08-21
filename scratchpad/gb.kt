fun prefixes(): List<String> = buildList {
    add("America/")
    add("Europe/")
    add("Asia/")
}

fun churn(n: Int): Int { var a = 0; for (i in 0 until n) { val s = "z" + i; a += s.length }; return a }

fun main() {
    val p = prefixes()
    println("size=" + p.size + " first=" + p.firstOrNull())
    churn(30)
    println("after churn size=" + p.size)
    val input = "America/New_York"
    println("match=" + p.firstOrNull { input.startsWith(it, 0) })
    churn(30)
    println("match2=" + prefixes().firstOrNull { input.startsWith(it, 0) })
}
