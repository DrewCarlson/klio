// A public class whose simple name another package also declares publicly.
package sample.linked

public open class ListHead {
    private val removedRef: String = "linked"
    public val marker: Int = 7
    public fun describe(): String = "linked:" + removedRef
}
