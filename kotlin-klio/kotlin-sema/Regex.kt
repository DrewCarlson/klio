// klio's `MatchResult.groups` for the sema pipeline: the groups of a host
// match as a Kotlin collection, so a type test and a call through any of
// its interfaces see a class of their own.

package kotlin.text

/** The groups of [match], by index and by the name a named group declares. */
internal class KlioMatchGroups(private val match: MatchResult) : AbstractCollection<MatchGroup?>(), MatchNamedGroupCollection {
    override val size: Int get() = __klioMatchGroupCount(match)

    override fun iterator(): Iterator<MatchGroup?> = object : Iterator<MatchGroup?> {
        private var next = 0

        override fun hasNext(): Boolean = next < size

        override fun next(): MatchGroup? {
            if (next >= size) throw NoSuchElementException()
            return get(next++)
        }
    }

    override fun get(index: Int): MatchGroup? = __klioMatchGroup(match, index)

    override fun get(name: String): MatchGroup? = __klioMatchNamedGroup(match, name)
}

/** A named group of the collection, as Kotlin/Native declares it. */
public actual operator fun MatchGroupCollection.get(name: String): MatchGroup? {
    val namedGroups = this as? MatchNamedGroupCollection
        ?: throw UnsupportedOperationException("Retrieving groups by name is not supported on this platform.")
    return namedGroups[name]
}

internal external fun __klioMatchGroupCount(match: MatchResult): Int

internal external fun __klioMatchGroup(match: MatchResult, index: Int): MatchGroup?

internal external fun __klioMatchNamedGroup(match: MatchResult, name: String): MatchGroup?
