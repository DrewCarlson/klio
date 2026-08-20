// An `inline` member of the enclosing class, called by bare name from inside a
// receiver lambda over a DIFFERENT type. Kotlin resolves the name against the
// enclosing class — `with(sb) { each { ... } }` calls `Holder.each`, because
// StringBuilder declares nothing by that name.
//
// A non-inline sibling reaches the enclosing receiver by walking outward from
// the lambda's receiver, and the inline one must reach the same declaration.
//
// Run with: klio run examples/inline_member_in_receiver_lambda.kt

class Holder(val n: Int) {
    inline fun eachInline(block: (Int) -> Unit) {
        for (i in 0 until n) block(i)
    }

    fun eachPlain(block: (Int) -> Unit) {
        for (i in 0 until n) block(i)
    }

    // No receiver lambda in the way.
    fun bare(): String {
        val sb = StringBuilder()
        eachInline { sb.append(it) }
        return sb.toString()
    }

    // `with` puts a StringBuilder receiver between the call and its owner.
    fun inWith(): String {
        val sb = StringBuilder()
        with(sb) { eachInline { sb.append(it) } }
        return sb.toString()
    }

    // `apply` does the same with the receiver bound to the built value.
    fun inApply(): String {
        val sb = StringBuilder()
        sb.apply { eachInline { sb.append(it) } }
        return sb.toString()
    }

    // The non-inline sibling in the same position, for comparison.
    fun plainInWith(): String {
        val sb = StringBuilder()
        with(sb) { eachPlain { sb.append(it) } }
        return sb.toString()
    }

    // An explicit qualifier names the same declaration.
    fun qualified(): String {
        val sb = StringBuilder()
        with(sb) { this@Holder.eachInline { sb.append(it) } }
        return sb.toString()
    }

    // Building the string through the receiver lambda itself.
    fun viaBuildString(): String = buildString {
        append('[')
        eachInline { append(it) }
        append(']')
    }
}

fun main() {
    val h = Holder(4)
    println("bare          = " + h.bare())
    println("in with       = " + h.inWith())
    println("in apply      = " + h.inApply())
    println("plain in with = " + h.plainInWith())
    println("qualified     = " + h.qualified())
    println("buildString   = " + h.viaBuildString())
}
