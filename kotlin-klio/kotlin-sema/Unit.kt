// klio `actual` the sema pipeline uses for Unit, whose value is the host's
// Unit: it renders as the JVM's does.

package kotlin

public actual object Unit {
    override fun toString(): String = "kotlin.Unit"
}
