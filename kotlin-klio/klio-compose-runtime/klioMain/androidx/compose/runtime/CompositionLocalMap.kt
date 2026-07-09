// klio's CompositionLocalMap — an immutable snapshot of the CompositionLocals in
// scope at one point in the composition. The node engine (androidx.compose.ui)
// stores one on each LayoutNode (via ComposeUiNode.SetResolvedCompositionLocals)
// so Modifier.Nodes can read locals off the tree with `currentValueOf`, outside a
// @Composable context. klio's composer produces these from its provider stack.

package androidx.compose.runtime

public sealed interface CompositionLocalMap {
    /** The value of [key] at this point in the hierarchy, or its default. */
    public operator fun <T> get(key: CompositionLocal<T>): T

    public companion object {
        /** An empty map: every local resolves to its default. */
        public val Empty: CompositionLocalMap = KlioCompositionLocalMap(emptyMap())
    }
}

internal class KlioCompositionLocalMap(
    private val values: Map<CompositionLocal<*>, Any?>,
) : CompositionLocalMap {
    @Suppress("UNCHECKED_CAST")
    override fun <T> get(key: CompositionLocal<T>): T =
        if (values.containsKey(key)) values[key] as T else key.defaultFactory()
}
