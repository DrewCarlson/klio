package kotlinx.io

public class Buffer {
    private val sb = StringBuilder()
    public fun writeString(s: String): Buffer { sb.append(s); return this }
    public fun readString(): String { val r = sb.toString(); sb.setLength(0); return r }
    override fun toString(): String = sb.toString()
}
public typealias Sink = Buffer
public typealias Source = Buffer
