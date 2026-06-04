package io.ktor.utils.io.charsets
public class Charset(public val name: String) {
    override fun equals(other: Any?): Boolean = other is Charset && other.name == name
    override fun hashCode(): Int = name.hashCode()
    override fun toString(): String = name
}
public object Charsets {
    public val UTF_8: Charset = Charset("UTF-8")
    public val ISO_8859_1: Charset = Charset("ISO-8859-1")
    public fun forName(name: String): Charset = when (name.uppercase()) {
        "UTF-8", "UTF8" -> UTF_8
        "ISO-8859-1", "LATIN1" -> ISO_8859_1
        else -> Charset(name)
    }
}
