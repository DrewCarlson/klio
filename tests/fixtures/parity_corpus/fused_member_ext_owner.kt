// A member extension whose body needs the implicit dispatch receiver
// (`this@Holder`) to call a sibling member extension, reached through an
// enclosing-chain-dependent dispatch. The body starts with fusible ops
// (enum compares) before the chain-dependent call, so a partial native
// prefix must hand the full receiver scope to the framed remainder — the
// member-extension owner and the extension subject both.
enum class Pad { PRESENT, ABSENT, OPTIONAL }

class Holder(val tag: String) {
    private fun Pad.isOptional(): Boolean =
        this == Pad.OPTIONAL

    private fun Pad.isAllowed(): Boolean =
        this == Pad.PRESENT || isOptional()

    private fun Pad.describe(): String =
        tag + ":" + this.name + "=" + isAllowed()

    fun run(): String {
        val parts = ArrayList<String>()
        for (p in Pad.entries) {
            if (p.isAllowed()) parts.add(p.name)
        }
        val direct = Pad.entries.filter { it.isAllowed() }.size
        return parts.joinToString(",") + "|" + direct + "|" + Pad.ABSENT.describe()
    }
}

fun main() {
    println(Holder("h").run())
    // A second instance: the owner recovered from the chain must be the
    // live receiver, not a memoized one.
    println(Holder("k").run())
}
