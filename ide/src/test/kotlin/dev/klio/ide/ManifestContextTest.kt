package dev.klio.ide

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The caret's context drives every manifest completion, and it is read from the
 * text rather than a parse tree, so each shape it has to recognise is pinned
 * here. `|` marks the caret.
 */
class ManifestContextTest {

    private fun contextAt(withCaret: String): ManifestContext {
        val offset = withCaret.indexOf('|')
        require(offset >= 0) { "the fixture must mark the caret with |" }
        return ManifestContext.at(withCaret.replace("|", ""), offset)
    }

    @Test
    fun aSectionHeaderCompletesSections() {
        assertEquals(Kind.SECTION, contextAt("[library]\nid = \"a\"\n\n[|").kind)
    }

    @Test
    fun aKeyUnderDepsCompletesDependencyIds() {
        val context = contextAt("[deps]\nstdlib = \"*\"\nkotlin|")
        assertEquals(Kind.DEP_ID, context.kind)
        assertEquals("deps", context.section)
        assertTrue("stdlib" in context.declaredDeps)
    }

    @Test
    fun anAlreadyDeclaredDependencyIsKnown() {
        val context = contextAt("[deps]\nstdlib = \"*\"\n\"kotlinx.io\" = \"*\"\n|")
        assertEquals(setOf("stdlib", "kotlinx.io"), context.declaredDeps)
    }

    @Test
    fun theValueSideOfADependencyCompletesVersions() {
        val context = contextAt("[deps]\n\"kotlinx.io\" = |")
        assertEquals(Kind.DEP_VALUE, context.kind)
        assertEquals("kotlinx.io", context.depId)
    }

    @Test
    fun anInlineTableCompletesItsKeys() {
        val context = contextAt("[deps]\n\"io.ktor\" = { |")
        assertEquals(Kind.DEP_TABLE_KEY, context.kind)
        assertEquals("io.ktor", context.depId)
    }

    @Test
    fun aSecondInlineTableKeyStillCompletes() {
        val context = contextAt("[deps]\n\"io.ktor\" = { version = \"*\", |")
        assertEquals(Kind.DEP_TABLE_KEY, context.kind)
    }

    @Test
    fun aFeatureArrayCompletesThatPacksFeatures() {
        val context = contextAt("[deps]\n\"io.ktor\" = { features = [|")
        assertEquals(Kind.DEP_FEATURE, context.kind)
        assertEquals("io.ktor", context.depId)
    }

    @Test
    fun aSecondFeatureInTheArrayStillCompletes() {
        val context = contextAt("[deps]\n\"io.ktor\" = { features = [\"client\", |")
        assertEquals(Kind.DEP_FEATURE, context.kind)
    }

    @Test
    fun aClosedFeatureArrayReturnsToTableKeys() {
        val context = contextAt("[deps]\n\"io.ktor\" = { features = [\"client\"], |")
        assertEquals(Kind.DEP_TABLE_KEY, context.kind)
    }

    @Test
    fun aKeyUnderLibraryCompletesLibraryKeys() {
        val context = contextAt("[library]\nid = \"a\"\nver|")
        assertEquals(Kind.TABLE_KEY, context.kind)
        assertEquals("library", context.section)
    }

    @Test
    fun aRepeatedSectionKeepsItsName() {
        val context = contextAt("[[source]]\nro|")
        assertEquals(Kind.TABLE_KEY, context.kind)
        assertEquals("source", context.section)
    }

    @Test
    fun aFeatureSubtableReportsItsParent() {
        val context = contextAt("[features.json]\nsou|")
        assertEquals("features", context.section)
    }

    @Test
    fun aCommentCompletesNothing() {
        assertEquals(Kind.NONE, contextAt("[deps]\n# a note |").kind)
    }

    @Test
    fun aValueOutsideDepsCompletesNothing() {
        assertEquals(Kind.NONE, contextAt("[library]\nid = |").kind)
    }
}

/**
 * A completion here brings its own delimiters, so the prefix it replaces has to
 * start at the one the user typed. Get this wrong and `[` + `[library]` spells
 * `[[library]]`.
 */
class ManifestPrefixTest {

    private fun prefixAt(withCaret: String): String {
        val offset = withCaret.indexOf('|')
        require(offset >= 0) { "the fixture must mark the caret with |" }
        return manifestPrefix(withCaret.replace("|", ""), offset)
    }

    @Test
    fun anOpeningBracketIsPartOfThePrefix() {
        assertEquals("[", prefixAt("[|"))
        assertEquals("[lib", prefixAt("[lib|"))
    }

    @Test
    fun aRepeatedSectionBracketIsTooPartOfThePrefix() {
        assertEquals("[[", prefixAt("[[|"))
        assertEquals("[[sou", prefixAt("[[sou|"))
    }

    @Test
    fun anOpeningQuoteIsPartOfThePrefix() {
        assertEquals("\"", prefixAt("[deps]\n\"|"))
        assertEquals("\"kotlinx.io", prefixAt("[deps]\n\"kotlinx.io|"))
    }

    @Test
    fun aBareKeywordNeedsNoDelimiter() {
        assertEquals("stdl", prefixAt("[deps]\nstdl|"))
        assertEquals("vers", prefixAt("[deps]\n\"a\" = { vers|"))
    }

    @Test
    fun aDottedIdStaysWhole() {
        assertEquals("\"androidx.compose.ui", prefixAt("[deps]\n\"androidx.compose.ui|"))
    }

    @Test
    fun nothingTypedYetIsAnEmptyPrefix() {
        assertEquals("", prefixAt("[deps]\n|"))
        assertEquals("", prefixAt("[deps]\nstdlib = |"))
    }
}
