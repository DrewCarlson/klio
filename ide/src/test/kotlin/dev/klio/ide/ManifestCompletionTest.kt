package dev.klio.ide

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * What the manifest offers, for a catalogue standing in for the installed packs.
 * The cases here are the ones that were wrong in the editor: a feature array
 * that offered nothing, and a prefix that made the insertion land beside what
 * was typed instead of replacing it.
 */
class ManifestCompletionTest {

    private val packs = listOf(
        KlioPackInfo(
            id = "kotlinx.serialization",
            version = "1.11.0",
            features = listOf(KlioPackFeature("json")),
        ),
        KlioPackInfo(
            id = "io.ktor",
            version = "3.5.1",
            features = listOf(
                KlioPackFeature("client", listOf("http", "events")),
                KlioPackFeature("server", listOf("http", "events")),
            ),
        ),
        KlioPackInfo(id = "kotlinx.datetime", version = "0.8.0"),
    )

    private fun offered(withCaret: String): List<String> {
        val offset = withCaret.indexOf('|')
        require(offset >= 0) { "the fixture must mark the caret with |" }
        val text = withCaret.replace("|", "")
        return completionsFor(ManifestContext.at(text, offset), packs).map { it.insert }
    }

    private fun prefixOf(withCaret: String): String {
        val offset = withCaret.indexOf('|')
        return manifestPrefix(withCaret.replace("|", ""), offset)
    }

    @Test
    fun anEmptyFeatureArrayOffersThatPacksFeatures() {
        assertEquals(
            listOf("\"json\""),
            offered("[deps]\n\"kotlinx.serialization\" = { features = [\"|"),
        )
    }

    @Test
    fun theOpeningQuoteOfAFeatureIsTheWholePrefix() {
        // `["` as a prefix matches no completion, which is what left the
        // insertion beside the quote rather than replacing it.
        assertEquals("\"", prefixOf("[deps]\n\"kotlinx.serialization\" = { features = [\"|"))
        assertEquals("\"js", prefixOf("[deps]\n\"kotlinx.serialization\" = { features = [\"js|"))
    }

    @Test
    fun everyOfferedFeatureStartsWithTheTypedPrefix() {
        val fixture = "[deps]\n\"io.ktor\" = { features = [\"|"
        val prefix = prefixOf(fixture)
        assertTrue(offered(fixture).all { it.startsWith(prefix) }, "an element that does not match is appended, not inserted")
    }

    @Test
    fun aFeatureArrayNeedsNoPackPrefix() {
        assertEquals(
            listOf("\"client\"", "\"server\""),
            offered("[deps]\n\"io.ktor\" = { features = [\"|"),
        )
    }

    @Test
    fun aPackWithoutFeaturesOffersNothing() {
        assertEquals(emptyList(), offered("[deps]\n\"kotlinx.datetime\" = { features = [\"|"))
    }

    @Test
    fun aFeatureDefinitionsDepsAreQualified() {
        val offers = offered("[features.json]\nsources = [\"shim\"]\ndeps = [\"|")
        assertEquals(
            listOf("\"kotlinx.serialization/json\"", "\"io.ktor/client\"", "\"io.ktor/server\""),
            offers,
        )
    }

    @Test
    fun anInlineFeatureDefinitionsDepsAreQualifiedToo() {
        val offers = offered("[features]\njson = { sources = [\"a\"], deps = [\"|")
        assertTrue("\"kotlinx.serialization/json\"" in offers)
    }

    @Test
    fun dependencyIdsSkipWhatIsAlreadyDeclared() {
        val offers = offered("[deps]\nstdlib = \"*\"\n\"io.ktor\" = \"*\"\n|")
        assertTrue("stdlib" !in offers)
        assertTrue("\"io.ktor\"" !in offers)
        assertTrue("\"kotlinx.datetime\"" in offers)
    }

    @Test
    fun aDependencyValueOffersItsInstalledVersion() {
        val offers = offered("[deps]\n\"io.ktor\" = |")
        assertEquals(listOf("\"*\"", "\"3.5.1\"", "{ version = \"*\" }"), offers)
    }

    @Test
    fun anInlineTableOffersItsKeys() {
        assertEquals(
            listOf("version", "features", "default_features"),
            offered("[deps]\n\"io.ktor\" = { |"),
        )
    }

    @Test
    fun aSectionHeaderOffersSections() {
        val offers = offered("[|")
        assertTrue("[deps]" in offers)
        assertTrue("[[source]]" in offers)
    }
}
