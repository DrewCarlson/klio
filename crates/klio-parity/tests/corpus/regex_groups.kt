fun main() {
    val r = Regex("(\\w+)=(\\d+)")
    val m = r.find("a=1 b=22 c=333")
    if (m != null) {
        println(m.value)
        println(m.groupValues[1])
        println(m.groupValues[2])
        println(m.groups[1]?.value)
        println(m.groups[2]?.range)
    }
    val rows = r.findAll("x=10 y=20 z=30").toList()
    for (row in rows) {
        println("${row.groupValues[1]}:${row.groupValues[2]}")
    }
    val me = Regex("a(b)c").matchEntire("abc")
    println(me?.value)
    println(me?.groupValues?.get(1))
    println(Regex("z").matchEntire("abc"))
}
