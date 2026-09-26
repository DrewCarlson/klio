// A class that extends only interfaces extends Any, so an unqualified super
// call reaches Any's members: beside an interface that redeclares equals and
// hashCode abstractly (as Compose's IndicationNodeFactory does),
// `super.equals(other)` and `super.hashCode()` call Any's identity versions.
interface Factory {
    fun make(): Int
    override fun equals(other: Any?): Boolean
    override fun hashCode(): Int
}

class Impl : Factory {
    override fun make() = 1
    override fun hashCode() = super.hashCode()
    override fun equals(other: Any?) = super.equals(other)
}

fun main() {
    val a = Impl()
    println(a == a)
    println(a == Impl())
    println(a.hashCode() == a.hashCode())
}
