package dev.klio.ide

import com.google.gson.Gson
import com.intellij.codeInsight.completion.CompletionContributor
import com.intellij.codeInsight.completion.CompletionParameters
import com.intellij.codeInsight.completion.CompletionResultSet
import com.intellij.codeInsight.completion.InsertionContext
import com.intellij.codeInsight.lookup.LookupElement
import com.intellij.codeInsight.completion.InsertHandler
import com.intellij.codeInsight.lookup.LookupElementBuilder
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.project.Project
import java.io.File

data class KlioPackInfo(
    val id: String = "",
    val version: String = "",
    val defaultFeatures: List<String> = emptyList(),
    val features: List<KlioPackFeature> = emptyList(),
    val dependencies: List<String> = emptyList(),
)

data class KlioPackFeature(val name: String = "", val requires: List<String> = emptyList())

private data class KlioPackCatalogue(val schema: Int = 0, val packs: List<KlioPackInfo> = emptyList())

/**
 * The installed packs a manifest can name, from `klio ide packs`.
 *
 * Completion runs under a read action, and a read action must not wait on a
 * process, so nothing here shells out on that path: [cached] answers from what a
 * sync already loaded, and asks for a load in the background when it cannot.
 * The list changes only when a pack is installed or removed, so one load lasts
 * until the next sync.
 */
object KlioPackCatalogueReader {
    private val log = logger<KlioPackCatalogueReader>()
    private val gson = Gson()

    /** Safe from any thread. Empty until a load lands. */
    fun cached(project: Project): List<KlioPackInfo> {
        val state = KlioProjectState.getInstance(project)
        state.packCatalogue?.let { return it }
        scheduleLoad(project)
        return emptyList()
    }

    /**
     * Runs klio. Call off the UI thread and outside a read action. A null
     * project is the new-project wizard, where the catalogue is still the same
     * installed set.
     */
    fun load(project: Project?): List<KlioPackInfo> {
        val json = KlioCli.run(listOf("ide", "packs"), File(project?.basePath ?: "."))
        return gson.fromJson(json, KlioPackCatalogue::class.java)?.packs.orEmpty()
    }

    fun scheduleLoad(project: Project) {
        val state = KlioProjectState.getInstance(project)
        if (!state.catalogueLoading.compareAndSet(false, true)) return
        ApplicationManager.getApplication().executeOnPooledThread {
            try {
                // A failure leaves the cache empty rather than caching the
                // emptiness, so the next completion tries again.
                state.packCatalogue = load(project)
            } catch (e: Exception) {
                log.info("klio ide packs failed", e)
            } finally {
                state.catalogueLoading.set(false)
            }
        }
    }
}

/** One thing completion can offer, before it becomes a lookup element. */
internal data class KlioCompletion(
    val insert: String,
    val presentable: String = insert,
    val tail: String = "",
    val type: String = "",
)

/**
 * What the caret's context offers, given the installed packs. Pure, so every
 * shape it has to answer for is pinned by a test rather than by clicking.
 */
internal fun completionsFor(context: ManifestContext, packs: List<KlioPackInfo>): List<KlioCompletion> =
    when (context.kind) {
        Kind.SECTION -> SECTIONS.map { (name, doc) -> KlioCompletion(name, type = doc) }

        Kind.DEP_ID -> buildList {
            if ("stdlib" !in context.declaredDeps) {
                add(KlioCompletion("stdlib", type = "the Kotlin standard library"))
            }
            for (pack in packs) {
                if (pack.id in context.declaredDeps) continue
                add(
                    KlioCompletion(
                        insert = "\"${pack.id}\"",
                        presentable = pack.id,
                        tail = if (pack.features.isEmpty()) "" else "  ${pack.features.size} feature(s)",
                        type = pack.version,
                    )
                )
            }
        }

        Kind.DEP_VALUE -> buildList {
            add(KlioCompletion("\"*\"", type = "any version"))
            packs.firstOrNull { it.id == context.depId }?.let {
                add(KlioCompletion("\"${it.version}\"", type = "installed version"))
            }
            add(KlioCompletion("{ version = \"*\" }", type = "version, features, default_features"))
        }

        Kind.DEP_TABLE_KEY -> DEP_TABLE_KEYS.map { (name, doc) -> KlioCompletion(name, type = doc) }

        // The pack is named to the left, so the feature stands alone here.
        Kind.DEP_FEATURE -> packs.firstOrNull { it.id == context.depId }
            ?.features
            ?.map { feature ->
                KlioCompletion(
                    insert = "\"${feature.name}\"",
                    presentable = feature.name,
                    tail = requiresTail(feature),
                    type = "feature",
                )
            }
            .orEmpty()

        // A feature of any pack, named whole.
        Kind.FEATURE_DEP -> packs.flatMap { pack ->
            pack.features.map { feature ->
                KlioCompletion(
                    insert = "\"${pack.id}/${feature.name}\"",
                    presentable = "${pack.id}/${feature.name}",
                    tail = requiresTail(feature),
                    type = "feature",
                )
            }
        }

        Kind.TABLE_KEY -> keysFor(context.section).map { (name, doc) -> KlioCompletion(name, type = doc) }

        Kind.NONE -> emptyList()
    }

private fun requiresTail(feature: KlioPackFeature): String =
    if (feature.requires.isEmpty()) "" else "  requires ${feature.requires.joinToString(", ")}"

private fun keysFor(section: String?): List<Pair<String, String>> = when (section) {
    "library" -> LIBRARY_KEYS
    "application" -> APPLICATION_KEYS
    "source" -> SOURCE_KEYS
    "test" -> TEST_KEYS
    "features" -> FEATURES_KEYS
    else -> emptyList()
}

private val SECTIONS = listOf(
    "[library]" to "id, version, abi, source roots",
    "[deps]" to "one line per dependency",
    "[bindings]" to "Kotlin FQN to host symbol",
    "[features]" to "named, opt-in source subsets",
    "[application]" to "the entry point klio bundle packages",
    "[[source]]" to "a packed source root",
    "[[test]]" to "a test source root",
)
private val DEP_TABLE_KEYS = listOf(
    "version" to "minimum version, or \"*\" for any",
    "features" to "features to enable",
    "default_features" to "false drops the pack's own defaults",
)
private val LIBRARY_KEYS = listOf(
    "id" to "globally unique library id",
    "version" to "SemVer",
    "abi" to "bump when bindings change shape",
    "source_roots" to "directories of .kt files",
    "implicit_packages" to "packages visible without import",
    "auto_bindings" to "bind host symbols by id prefix",
)
private val APPLICATION_KEYS = listOf(
    "main" to "the file declaring main",
    "name" to "bundle name",
    "icon" to "bundle icon",
    "sources" to "extra sources to bundle",
    "includes" to "resources, as path[:mount]",
)
private val SOURCE_KEYS = listOf(
    "root" to "directory, relative to the manifest",
    "include" to "file patterns to keep",
    "exclude" to "file patterns to drop",
)
private val TEST_KEYS = listOf(
    "root" to "directory, relative to the manifest",
    "include" to "file patterns to keep",
    "feature" to "compose only when this feature is active",
)
private val FEATURES_KEYS = listOf(
    "default" to "features active when a consumer names none",
)

/**
 * Completion inside `klio.toml`. The manifest is small and its grammar is
 * shallow, so the caret's context comes from the line it sits on and the
 * section header above it rather than from a TOML parse tree: that keeps the
 * plugin independent of whichever TOML support the IDE ships.
 */
class KlioManifestCompletionContributor : CompletionContributor() {

    override fun fillCompletionVariants(parameters: CompletionParameters, base: CompletionResultSet) {
        val file = parameters.originalFile
        if (file.name != KLIO_MANIFEST) return

        val text = parameters.editor.document.text
        val offset = parameters.editor.caretModel.offset
        val context = ManifestContext.at(text, offset)

        // A completion here carries its own delimiters (`[library]`, `"io.ktor"`),
        // so the one the user already typed has to be part of the prefix. Left
        // out, the insertion lands beside it and spells `[[library]]`.
        val result = base.withPrefixMatcher(manifestPrefix(text, offset))

        for (completion in completionsFor(context, KlioPackCatalogueReader.cached(file.project))) {
            result.addElement(
                LookupElementBuilder.create(completion.insert)
                    .withInsertHandler(TrimAutoClosed)
                    .withPresentableText(completion.presentable)
                    .withTailText(completion.tail, true)
                    .withTypeText(completion.type, true)
            )
        }
    }
}

private object TrimAutoClosed : InsertHandler<LookupElement> {
    override fun handleInsert(context: InsertionContext, item: LookupElement) {
        val inserted = item.lookupString
        val closer = inserted.lastOrNull() ?: return
        if (closer != ']' && closer != '"' && closer != '}') return
        val run = inserted.takeLastWhile { it == closer }.length

        val document = context.document
        val text = document.charsSequence
        var end = context.tailOffset
        var removed = 0
        while (removed < run && end < text.length && text[end] == closer) {
            end++
            removed++
        }
        if (removed > 0) document.deleteString(context.tailOffset, end)
    }
}

/**
 * The text the completion replaces: the identifier under the caret with the
 * delimiter that opened it. A quote takes one quote and never the `[` of the
 * array around it, since a prefix matching no completion is appended beside
 * what was typed instead of replacing it. Brackets count only at a section
 * header, the one place they open a name rather than a list.
 */
internal fun manifestPrefix(text: String, offset: Int): String {
    val safeOffset = offset.coerceIn(0, text.length)
    var start = safeOffset
    while (start > 0 && (text[start - 1].isLetterOrDigit() || text[start - 1] in "./-_")) start--
    if (start > 0 && text[start - 1] == '"') return text.substring(start - 1, safeOffset)

    var bracketed = start
    while (bracketed > 0 && text[bracketed - 1] == '[') bracketed--
    val lineStart = text.lastIndexOf('\n', (bracketed - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
    val onlyBracketsBefore = bracketed == start || text.substring(lineStart, bracketed).isBlank()
    if (onlyBracketsBefore) return text.substring(bracketed, safeOffset)
    return text.substring(start, safeOffset)
}

internal enum class Kind {
    NONE,
    SECTION,
    TABLE_KEY,
    DEP_ID,
    DEP_VALUE,
    DEP_TABLE_KEY,

    /** Inside a dependency's `features = [...]`, where the pack is already named. */
    DEP_FEATURE,

    /** Inside a feature's `deps = [...]`, which spells a feature `<pack>/<feature>`. */
    FEATURE_DEP,
}

/**
 * Where the caret sits, read from the text around it: the section header above,
 * whether the line is a key or a value, and for a dependency, which one.
 */
internal data class ManifestContext(
    val kind: Kind,
    val section: String? = null,
    val depId: String? = null,
    val declaredDeps: Set<String> = emptySet(),
) {
    companion object {
        fun at(text: String, offset: Int): ManifestContext {
            val safeOffset = offset.coerceIn(0, text.length)
            val lineStart = text.lastIndexOf('\n', (safeOffset - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
            val before = text.substring(lineStart, safeOffset)
            val trimmed = before.trimStart()

            if (trimmed.startsWith("#")) return ManifestContext(Kind.NONE)
            if (trimmed.startsWith("[")) return ManifestContext(Kind.SECTION)

            val section = sectionAt(text, lineStart)
            val eq = before.indexOf('=')

            if (eq < 0) {
                // Key position: a dependency id under `[deps]`, else a table key.
                val kind = if (section == "deps") Kind.DEP_ID else Kind.TABLE_KEY
                return ManifestContext(kind, section, declaredDeps = declaredDeps(text))
            }

            val afterEq = before.substring(eq + 1)
            val depId = before.substring(0, eq).trim().trim('"')
            if (section == "features") {
                // `deps = ["kotlinx.serialization/json"]`, in a feature table or
                // an inline one. A feature names another pack's feature whole.
                val field = afterEq.substringAfterLast('{').substringAfterLast(',')
                val key = if (field.contains('=')) field.substringBefore('=').trim() else depId
                val open = afterEq.lastIndexOf('[')
                if (key == "deps" && open >= 0 && !afterEq.substring(open).contains(']')) {
                    return ManifestContext(Kind.FEATURE_DEP, section)
                }
                return ManifestContext(Kind.NONE, section)
            }
            if (section != "deps") {
                return ManifestContext(Kind.NONE, section)
            }
            val brace = afterEq.lastIndexOf('{')
            if (brace < 0) return ManifestContext(Kind.DEP_VALUE, section, depId)

            // Inside an inline table: an unclosed `features = [` wants feature
            // names, anything else wants one of the table's keys.
            val inTable = afterEq.substring(brace + 1)
            val bracket = inTable.lastIndexOf('[')
            if (bracket >= 0 && !inTable.substring(bracket).contains(']')) {
                val field = inTable.substring(0, bracket).substringAfterLast(',').substringBefore('=').trim()
                if (field == "features") return ManifestContext(Kind.DEP_FEATURE, section, depId)
                return ManifestContext(Kind.NONE, section, depId)
            }
            val lastField = inTable.substringAfterLast(',')
            if (lastField.contains('=')) return ManifestContext(Kind.NONE, section, depId)
            return ManifestContext(Kind.DEP_TABLE_KEY, section, depId)
        }

        /** The section header governing `lineStart`, without its brackets. */
        private fun sectionAt(text: String, lineStart: Int): String? {
            var i = lineStart
            while (i > 0) {
                val prevEnd = text.lastIndexOf('\n', i - 2)
                val start = if (prevEnd < 0) 0 else prevEnd + 1
                val line = text.substring(start, (i - 1).coerceAtLeast(start)).trim()
                if (line.startsWith("[")) {
                    return line.trim('[', ']', ' ').substringBefore('.')
                }
                if (start == 0) return null
                i = start
            }
            return null
        }

        /** Ids already named under `[deps]`, so completion does not offer them twice. */
        private fun declaredDeps(text: String): Set<String> {
            val out = HashSet<String>()
            var inDeps = false
            for (raw in text.lineSequence()) {
                val line = raw.substringBefore('#').trim()
                if (line.startsWith("[")) {
                    inDeps = line == "[deps]"
                    continue
                }
                if (!inDeps || line.isEmpty()) continue
                val key = line.substringBefore('=').trim().trim('"')
                if (key.isNotEmpty()) out.add(key)
            }
            return out
        }
    }
}
