// A MEMBER-EXTENSION property (`private val Any?.tagOrNull` inside a class)
// belongs to the extension surface, not the class's own property set: a
// subtype instance passed back through an inherited reader still resolves
// the read through the extension, and the property never shadows anything
// as an instance member.

open class BaseSupport {
    private val Any?.tagOrNull: String?
        get() = (this as? Marked)?.tag

    fun readTag(x: Any?): String? = x.tagOrNull
}

class Marked(val tag: String)
open class Mid : BaseSupport()
class SubSupport : Mid()

fun main() {
    println(SubSupport().readTag(Marked("t")))
    println(SubSupport().readTag(SubSupport()))
    println(SubSupport().readTag(null))
}
