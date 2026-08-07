class Named(val n: String) { fun tag(): String = "<$n>" }

class Holder(private val items: IntArray, val label: Named) {
    var summary: String = ""
    init {
        // An init block reads the constructor's parameters.
        summary = items.copyOf().size.toString() + label.tag()
    }

    var extra: String = ""

    constructor(single: Int, tag: Named, note: Named) : this(intArrayOf(single), tag) {
        // A secondary constructor BODY reads its own parameters.
        extra = note.tag() + single.toLong().toString()
    }
}

fun main() {
    val a = Holder(intArrayOf(1, 2, 3), Named("a"))
    println(a.summary + "|" + a.extra)
    val b = Holder(7, Named("b"), Named("c"))
    println(b.summary + "|" + b.extra)
}
