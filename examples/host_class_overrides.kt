// A Kotlin subclass of a collection class the host implements overrides its
// members, as on the JVM, where `ArrayList` and `HashMap` are open: a call
// through the base type runs the override, and the override's `super` call
// runs the host's implementation.

open class BaseStringList : ArrayList<String>()

class StringList : BaseStringList() {
    override fun get(index: Int): String = "StringList.get()"
}

class PlusOne : ArrayList<Int>() {
    override fun get(index: Int): Int = super.get(index) + 1
    override val size: Int get() = super.size * 10
}

class CountingMap : HashMap<String, Int>() {
    var puts = 0
    override fun put(key: String, value: Int): Int? {
        puts++
        return super.put(key, value)
    }
}

fun main() {
    val s = StringList()
    s.add("first element")
    val b: BaseStringList = s
    val a: ArrayList<String> = s
    val l: List<String> = s
    println(s.get(0) + " " + b.get(0) + " " + a.get(0) + " " + l[0])

    val plain = BaseStringList()
    plain.add("plain")
    println(plain.get(0) + " " + (plain as ArrayList<String>).get(0))

    val p = PlusOne()
    p.add(41)
    val pa: ArrayList<Int> = p
    println("${p.get(0)} ${pa.get(0)} ${pa[0]} ${p.size} ${pa.size}")

    val m = CountingMap()
    val hm: HashMap<String, Int> = m
    hm.put("a", 1)
    hm["b"] = 2
    m.put("c", 3)
    println("${m.puts} ${hm.size} ${hm["b"]}")
}
