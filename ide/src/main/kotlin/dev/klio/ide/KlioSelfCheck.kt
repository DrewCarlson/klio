@file:Suppress("UnstableApiUsage")

package dev.klio.ide

import com.intellij.execution.actions.ConfigurationContext
import com.intellij.ide.impl.OpenProjectTask
import com.intellij.openapi.application.ModernApplicationStarter
import com.intellij.openapi.application.readAction
import com.intellij.openapi.module.ModuleManager
import com.intellij.openapi.module.ModuleUtilCore
import com.intellij.openapi.project.DumbService
import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ex.ProjectManagerEx
import com.intellij.openapi.roots.ModuleRootManager
import com.intellij.openapi.roots.ProjectFileIndex
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VfsUtilCore
import com.intellij.psi.PsiManager
import com.intellij.psi.util.PsiTreeUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.jetbrains.kotlin.analysis.api.analyze
import org.jetbrains.kotlin.analysis.api.components.KaDiagnosticCheckerFilter
import org.jetbrains.kotlin.analysis.api.permissions.KaAllowAnalysisOnEdt
import org.jetbrains.kotlin.analysis.api.permissions.allowAnalysisOnEdt
import org.jetbrains.kotlin.analysis.api.symbols.KaConstructorSymbol
import org.jetbrains.kotlin.idea.references.mainReference
import org.jetbrains.kotlin.psi.KtFile
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtNamedFunction
import java.io.File
import java.nio.file.Path
import kotlin.system.exitProcess

/**
 * A headless run of the whole integration: open a klio project, build the
 * workspace from `klio ide model`, then ask the Kotlin frontend to resolve the
 * result. Prints one `[selfcheck]` line per assertion and exits non-zero on the
 * first failure, so the IDE side is verifiable without a window.
 *
 * `runIde --args="klio-selfcheck <project-dir>"`.
 */
class KlioSelfCheckStarter : ModernApplicationStarter() {
    override val isHeadless: Boolean get() = true

    override suspend fun start(args: List<String>) {
        val projectPath = args.getOrNull(1)
        if (projectPath == null) {
            println("[selfcheck] usage: klio-selfcheck <project-dir>")
            exitProcess(2)
        }
        var failures = 0
        try {
            val project = ProjectManagerEx.getInstanceEx()
                .openProjectAsync(Path.of(projectPath), OpenProjectTask { })
                ?: error("could not open $projectPath")

            report("project opened", true, projectPath)

            // Analysis of a file the editor reaches before the import lands is
            // cached; if the import does not invalidate it, the project resolves
            // nothing until the user syncs a second time by hand.
            val stale = warmStaleAnalysis(project, projectPath)

            // `KLIO_SELFCHECK_OPEN_SYNC=1` leaves the import to the startup
            // activity, which is what a user gets when they open a project: the
            // starter asserts against that sync rather than one of its own.
            // `KLIO_SELFCHECK_NO_SYNC=1` asserts against the persisted workspace
            // alone, which is what an editor sees the moment a project opens.
            val model = if (System.getenv("KLIO_SELFCHECK_NO_SYNC") == "1") {
                KlioCli.model(project).also { KlioProjectState.getInstance(project).claimOpenSync() }
            } else if (System.getenv("KLIO_SELFCHECK_OPEN_SYNC") == "1") {
                awaitOpenSync(project)
            } else {
                KlioProjectImporter.syncOnOpen(project) ?: KlioProjectImporter.sync(project)
            }
            report("model synced", model.modules.isNotEmpty(), "${model.modules.size} modules, problems=${model.problems}")

            // Indexing the materialised packs outlasts the first smart-mode
            // report, and analysis of a file not yet in a module answers with
            // silence rather than an error, so wait for the index to place every
            // user source before asserting anything about it.
            DumbService.getInstance(project).waitForSmartMode()
            awaitFileIndex(project, model.modules.filter { !it.isLibrary }.flatMap { it.contentRoots })

            report("analysed before the import", true, stale)

            failures += checkUserCode(project, model)
            failures += checkNavigation(project, model)
            failures += checkLibrarySource(project, model)
            failures += checkRunConfigurations(project, model)
            failures += checkSyncBanner(project, projectPath)
            failures += checkPackCatalogue(project, model)
            surveyLibraryResolution(project, model)
            failures += checkNoJdk(project, model)
            failures += checkReadOnlyPackSources(project, model)
            failures += checkWizardOutput(project)
            failures += checkUiFacingQueries()
        } catch (e: Throwable) {
            println("[selfcheck] FAIL exception: ${e.stackTraceToString()}")
            failures++
        }
        println("[selfcheck] done, $failures failure(s)")
        exitProcess(if (failures == 0) 0 else 1)
    }

    /**
     * Resolves a user file before any import has run, so its answer (no module,
     * nothing resolves) is in the caches when the import lands.
     */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun warmStaleAnalysis(project: Project, projectPath: String): String = try {
        readAction {
            val file = collectKtFiles(project, "$projectPath/src/main/kotlin").firstOrNull()
                ?: return@readAction "no source to warm"
            allowAnalysisOnEdt {
                analyze(file) {
                    val count = file.collectDiagnostics(
                        KaDiagnosticCheckerFilter.ONLY_COMMON_CHECKERS
                    ).count()
                    "${file.name}: $count diagnostic(s) before the import"
                }
            }
        }
    } catch (e: Throwable) {
        "warm-up threw ${e::class.simpleName}"
    }

    /** Waits for whatever sync the project's own open triggered. */
    private suspend fun awaitOpenSync(project: Project): KlioProjectModel {
        val deadline = System.currentTimeMillis() + 120_000
        while (System.currentTimeMillis() < deadline) {
            KlioProjectState.getInstance(project).model?.let { return it }
            delay(500)
        }
        error("the project opened without a klio sync")
    }

    /** The user's own file must resolve against the materialised stdlib with no errors. */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun checkUserCode(project: Project, model: KlioProjectModel): Int {
        var failures = 0
        val roots = model.modules.filter { !it.isLibrary }.flatMap { it.contentRoots }
        if (roots.isEmpty()) {
            report("user module present", false, "none in model")
            return 1
        }
        val files = readAction { roots.flatMap { collectKtFiles(project, it) } }
        report("user sources found", files.isNotEmpty(), "${files.size} file(s), main and test")
        if (files.isEmpty()) return 1

        for (file in files) {
            val diagnostics = readAction {
                allowAnalysisOnEdt {
                    analyze(file) {
                            file.collectDiagnostics(
                                KaDiagnosticCheckerFilter.ONLY_COMMON_CHECKERS
                        ).map { "${it.severity} ${it.factoryName}: ${it.defaultMessage.take(160)}" }
                    }
                }
            }
            val errors = diagnostics.filter { it.startsWith("ERROR") }
            report("no errors in ${file.name}", errors.isEmpty(), errors.joinToString("; ").take(600))
            if (errors.isNotEmpty()) failures++
        }
        return failures
    }

    /**
     * Go to definition, the headline feature: a reference in the user's code must
     * resolve to a declaration in materialised pack source on disk.
     */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun checkNavigation(project: Project, model: KlioProjectModel): Int {
        val userModule = model.modules.firstOrNull { !it.isLibrary && !it.isTest } ?: return 1
        val root = userModule.contentRoots.firstOrNull() ?: return 1
        val files = readAction { collectKtFiles(project, root) }
        var failures = 0
        for (name in listOf("listOf", "joinToString", "map", "LocalDate")) {
            val referenced = readAction { files.any { findReference(it, name) != null } }
            if (!referenced) continue
            val target = readAction {
                allowAnalysisOnEdt {
                    files.firstNotNullOfOrNull { file ->
                        findReference(file, name)?.let { reference ->
                            analyze(reference) {
                                val symbols = reference.mainReference.resolveToSymbols()
                                val located = symbols.firstNotNullOfOrNull { symbol ->
                                    symbol.psi?.containingFile?.virtualFile?.path
                                        ?: (symbol as? KaConstructorSymbol)
                                            ?.containingDeclaration?.psi?.containingFile?.virtualFile?.path
                                }
                                located ?: symbols.firstOrNull()?.let { "resolved to ${it::class.simpleName} with no source" }
                            }
                        }
                    }
                }
            }
            val ok = target != null
            report("`$name` resolves to a declaration", ok, target?.substringAfter("/.klio/ide/") ?: "unresolved")
            if (!ok) failures++
        }
        return failures
    }

    private fun findReference(file: KtFile, name: String): KtNameReferenceExpression? =
        PsiTreeUtil.findChildrenOfType(file, KtNameReferenceExpression::class.java)
            .firstOrNull { it.getReferencedName() == name }

    /**
     * The materialised stdlib itself: the `actual` roots must match the `expect`
     * roots across the refinement edge, which is the whole reason the model
     * emits two modules per library.
     */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun checkLibrarySource(project: Project, model: KlioProjectModel): Int {
        val actualModule = model.modules.firstOrNull { it.isLibrary && it.dependsOn.isNotEmpty() } ?: run {
            report("a refining library module exists", false, "none in model")
            return 1
        }
        val root = actualModule.contentRoots.firstOrNull() ?: return 1
        val files = readAction { collectKtFiles(project, root) }
            .filter { file -> readAction { file.text.contains("actual ") } }
        report("actual-bearing sources found", files.isNotEmpty(), "${files.size} file(s)")
        if (files.isEmpty()) return 1

        var mismatches = 0
        val sample = files.take(6)
        for (file in sample) {
            val errors = readAction {
                allowAnalysisOnEdt {
                    analyze(file) {
                            file.collectDiagnostics(
                                KaDiagnosticCheckerFilter.ONLY_COMMON_CHECKERS
                            )
                            .filter { it.severity.name == "ERROR" }
                            .map { "${it.factoryName}: ${it.defaultMessage.take(120)}" }
                    }
                }
            }
            val expectActual = errors.filter { error ->
                val factory = error.substringBefore(':')
                factory.startsWith("EXPECT") || factory.startsWith("ACTUAL") ||
                    factory.startsWith("NO_ACTUAL") || factory.startsWith("NO_EXPECT")
            }
            if (expectActual.isNotEmpty()) mismatches++
            report("expect/actual matched in ${file.name}", expectActual.isEmpty(), expectActual.joinToString("; ").take(400))
            if (errors.isNotEmpty()) {
                println("[selfcheck]   other errors in ${file.name}: ${errors.take(5).joinToString("; ").take(400)}")
            }
        }
        return mismatches
    }

    /**
     * The run configurations a right-click would produce: one for `fun main`,
     * one for an `@Test`, each with the command line klio will actually see.
     */
    private suspend fun checkRunConfigurations(project: Project, model: KlioProjectModel): Int {
        val roots = model.modules.filter { !it.isLibrary }.flatMap { it.contentRoots }
        return checkProducer("run", KlioRunConfigurationProducer(), project, roots, ::isMain) +
            checkProducer("test", KlioTestConfigurationProducer(), project, roots, ::isTest)
    }

    /** The workspace commit settles asynchronously; the file index follows it. */
    private suspend fun awaitFileIndex(project: Project, roots: List<String>) {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            DumbService.getInstance(project).waitForSmartMode()
            val indexed = readAction {
                val files = roots.flatMap { collectKtFiles(project, it) }
                files.isNotEmpty() && files.all { file ->
                    file.virtualFile?.let {
                        ProjectFileIndex.getInstance(project).getModuleForFile(it)
                    } != null
                }
            }
            if (indexed) return
            delay(500)
        }
    }

    /**
     * PSI is re-read inside the same read action that asks the producer, so an
     * import that invalidated an earlier tree cannot make this look like a
     * declined configuration.
     */
    private suspend fun checkProducer(
        label: String,
        producer: KlioConfigurationProducerBase,
        project: Project,
        roots: List<String>,
        predicate: (KtNamedFunction) -> Boolean,
    ): Int {
        val diagnosis = readAction {
            val element = roots.asSequence()
                .flatMap { collectKtFiles(project, it).asSequence() }
                .flatMap {
                    PsiTreeUtil.findChildrenOfType(it, KtNamedFunction::class.java)
                        .asSequence()
                }
                .firstOrNull(predicate)
                ?: return@readAction "no candidate function"

            val module = ModuleUtilCore.findModuleForPsiElement(element)?.name
            val context = ConfigurationContext(element)
            val settings = try {
                producer.createConfigurationFromContext(context)
            } catch (e: Throwable) {
                return@readAction "threw ${e::class.simpleName}: ${e.message}"
            }
            (settings?.configuration as? KlioRunConfiguration)?.buildCommandLine()?.commandLineString
                ?: "declined (module=$module, fn=${element.name})"
        }
        val ok = diagnosis.contains("klio")
        report("$label configuration builds", ok, diagnosis.substringAfterLast('/'))
        return if (ok) 0 else 1
    }

    /**
     * The manifest banner: absent while the model matches the manifest, present
     * once the manifest is edited.
     */
    private suspend fun checkSyncBanner(project: Project, projectPath: String): Int {
        val manifest = LocalFileSystem.getInstance().refreshAndFindFileByPath("$projectPath/$KLIO_MANIFEST")
        if (manifest == null) {
            report("manifest found for the banner", false, "$projectPath/$KLIO_MANIFEST")
            return 1
        }
        val provider = KlioSyncNotificationProvider()
        val state = KlioProjectState.getInstance(project)
        var failures = 0

        val whenSynced = readAction { provider.collectNotificationData(project, manifest) }
        report("no banner while the model is current", whenSynced == null, whenSynced?.let { "banner shown" } ?: "")
        if (whenSynced != null) failures++

        state.manifestDirty = true
        val whenDirty = readAction { provider.collectNotificationData(project, manifest) }
        report("banner after the manifest changes", whenDirty != null, "")
        if (whenDirty == null) failures++
        state.manifestDirty = false

        val other = LocalFileSystem.getInstance().refreshAndFindFileByPath("$projectPath/README.md")
        if (other != null) {
            val onOther = readAction { provider.collectNotificationData(project, other) }
            report("no banner on other files", onOther == null, "")
            if (onOther != null) failures++
        }
        return failures
    }

    /**
     * Manifest completion offers what `klio ide packs` reports, and reads it
     * from the cache a sync filled: completion runs under a read action, which
     * must never wait on a process.
     */
    private suspend fun checkPackCatalogue(project: Project, model: KlioProjectModel): Int {
        val packs = readAction { KlioPackCatalogueReader.cached(project) }
        val ids = packs.map { it.id }.toSet()
        report("pack catalogue ready without leaving the read action", packs.isNotEmpty(), "${packs.size} installed")
        if (packs.isEmpty()) return 1

        // The guard that keeps it that way.
        val refused = try {
            readAction { KlioCli.run(listOf("ide", "packs"), File(projectRoot(model))) }
            false
        } catch (e: KlioCliException) {
            true
        }
        report("klio refuses to run under a read action", refused, "")
        if (!refused) failuresFromGuard = 1

        // Every library the model resolved is a pack a manifest could name.
        val wanted = model.modules
            .filter { it.isLibrary }
            .map { it.id.substringBefore(':') }
            .toSet() - "stdlib"
        val missing = wanted - ids
        report("catalogue covers the resolved libraries", missing.isEmpty(), missing.joinToString(", "))
        return failuresFromGuard + if (missing.isEmpty()) 0 else 1
    }

    private var failuresFromGuard = 0

    private fun projectRoot(model: KlioProjectModel): String = model.project.root

    /**
     * What a pack's own sources look like when opened. They are not highlighted,
     * but a reader still navigates and completes in them, and that needs them to
     * resolve. This reports rather than asserts: klio tolerates unresolved
     * references on paths it never runs, so some of this is expected and the
     * point is to see how much.
     */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun surveyLibraryResolution(project: Project, model: KlioProjectModel) {
        for (entry in model.modules.filter { it.isLibrary }) {
            val root = entry.contentRoots.firstOrNull() ?: continue
            val paths = readAction { collectKtPaths(project, root) }.take(12)
            if (paths.isEmpty()) continue
            var clean = 0
            val worst = LinkedHashMap<String, Int>()
            for (path in paths) {
                val unresolved = readAction {
                    val file = ktFile(project, path) ?: return@readAction 0
                    allowAnalysisOnEdt {
                        analyze(file) {
                            file.collectDiagnostics(
                                KaDiagnosticCheckerFilter.ONLY_COMMON_CHECKERS
                            ).count { it.factoryName.startsWith("UNRESOLVED") }
                        }
                    }
                }
                if (unresolved == 0) clean++ else worst[path.substringAfterLast('/')] = unresolved
            }
            val detail = worst.entries.take(3).joinToString(", ") { "${it.key}:${it.value}" }
            println(
                "[selfcheck]   library ${entry.id}: $clean/${paths.size} files resolve clean" +
                    if (detail.isEmpty()) "" else " — worst: $detail"
            )
        }
    }

    /**
     * klio has no JDK, and a module that inherits one would resolve `java.*` in
     * a program that cannot use it, besides listing the JDK among the project's
     * libraries. The scratch file is the test: `java.io.File` must not resolve.
     */
    @OptIn(KaAllowAnalysisOnEdt::class)
    private suspend fun checkNoJdk(project: Project, model: KlioProjectModel): Int {
        var failures = 0
        // Only the modules klio creates: a project opened as a folder also has
        // one of IntelliJ's own, and that one is not ours to strip.
        val ours = model.modules.map { KlioProjectImporter.moduleName(it.id) }.toSet()
        val withSdk = readAction {
            ModuleManager.getInstance(project).modules
                .filter { it.name in ours }
                .filter { ModuleRootManager.getInstance(it).sdk != null }
                .map { it.name }
        }
        val present = readAction {
            ModuleManager.getInstance(project).modules.count { it.name in ours }
        }
        report(
            "no klio module carries an SDK",
            withSdk.isEmpty() && present > 0,
            "$present of ${ours.size} modules${if (withSdk.isEmpty()) "" else ", with SDK: ${withSdk.joinToString(", ")}"}",
        )
        if (withSdk.isNotEmpty()) failures++

        val root = model.modules.first { !it.isLibrary && !it.isTest }.contentRoots.first()
        val scratch = File(root, "KlioJdkProbeScratch.kt")
        scratch.writeText("package dev.klio.sample.probe\n\nfun probe(): java.io.File = java.io.File(\"x\")\n")
        LocalFileSystem.getInstance().refreshAndFindFileByPath(root)?.refresh(false, true)
        try {
            val unresolved = readAction {
                val file = LocalFileSystem.getInstance()
                    .refreshAndFindFileByPath(scratch.absolutePath) ?: return@readAction false
                val psi = PsiManager.getInstance(project).findFile(file) as? KtFile
                    ?: return@readAction false
                allowAnalysisOnEdt {
                    analyze(psi) {
                        psi.collectDiagnostics(
                            KaDiagnosticCheckerFilter.ONLY_COMMON_CHECKERS
                        ).any { it.factoryName.startsWith("UNRESOLVED") }
                    }
                }
            }
            report("java.* does not resolve in klio code", unresolved, if (unresolved) "" else "the JDK is in scope")
            if (!unresolved) failures++
        } finally {
            scratch.delete()
            LocalFileSystem.getInstance().refreshAndFindFileByPath(root)?.refresh(false, true)
        }
        return failures
    }

    /**
     * The two questions a panel asks klio: which binary, and which packs. Both
     * are built on the UI thread, where running klio is refused, so both have to
     * work from a pooled thread and neither may be called inline. A settings
     * page that reports the binary "did not answer" and a wizard that reports no
     * packs installed are the same mistake seen twice.
     */
    private suspend fun checkUiFacingQueries(): Int {
        var failures = 0
        val status = withContext(Dispatchers.IO) { KlioCli.describeStatus() }
        val healthy = status.startsWith("klio ")
        report("the settings page reports a usable klio", healthy, status)
        if (!healthy) failures++

        // The settings page as it is actually built, on the UI thread, with its
        // label read back once the answer lands.
        val configurable = KlioSettingsConfigurable()
        withContext(Dispatchers.Main) { configurable.createPanel() }
        var shown = ""
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            shown = withContext(Dispatchers.Main) { configurable.detected.text }
            if (shown.startsWith("klio ")) break
            delay(250)
        }
        val panelOk = shown.startsWith("klio ")
        report("the settings panel fills in its status", panelOk, shown)
        if (!panelOk) failures++

        // The wizard and the settings page both run on the UI thread, where
        // running klio directly is refused. This is the path they use.
        val fromEdt = withContext(Dispatchers.Main) {
            try {
                KlioCli.runWithProgress(listOf("--version"), File("."), "Checking klio").trim()
            } catch (e: Exception) {
                "failed: ${e.message}"
            }
        }
        val edtOk = fromEdt.startsWith("klio ")
        report("klio answers from the UI thread through progress", edtOk, fromEdt)
        if (!edtOk) failures++

        val packs = withContext(Dispatchers.IO) { KlioPackCatalogueReader.load(null) }
        report("the wizard's catalogue loads without a project", packs.isNotEmpty(), "${packs.size} installed")
        if (packs.isEmpty()) failures++
        return failures
    }

    /** A materialised pack file is a view of the pack, so the editor refuses it. */
    private suspend fun checkReadOnlyPackSources(project: Project, model: KlioProjectModel): Int {
        val extension = KlioReadOnlyPackSources(project)
        val packRoot = model.modules.first { it.isLibrary }.contentRoots.first()
        val userRoot = model.modules.first { !it.isLibrary }.contentRoots.first()

        val packFile = readAction { collectKtPaths(project, packRoot).firstOrNull() }
        val userFile = readAction { collectKtPaths(project, userRoot).firstOrNull() }
        if (packFile == null || userFile == null) {
            report("files found to check writability", false, "pack=$packFile user=$userFile")
            return 1
        }

        var failures = 0
        val packLocked = readAction {
            LocalFileSystem.getInstance().refreshAndFindFileByPath(packFile)?.let { extension.isNotWritable(it) }
        }
        report("a pack source is not writable", packLocked == true, packFile.substringAfterLast('/'))
        if (packLocked != true) failures++

        val userLocked = readAction {
            LocalFileSystem.getInstance().refreshAndFindFileByPath(userFile)?.let { extension.isNotWritable(it) }
        }
        report("the user's own source stays writable", userLocked == false, userFile.substringAfterLast('/'))
        if (userLocked != false) failures++
        return failures
    }

    /**
     * What New Project produces has to be a project klio can actually model,
     * run and test. The wizard's own content functions write it, so this covers
     * the same bytes a user would get.
     */
    private suspend fun checkWizardOutput(project: Project): Int {
        val dir = java.nio.file.Files.createTempDirectory("klio-wizard-check").toFile()
        var failures = 0
        try {
            val id = "com.example.wizardcheck"
            // Exactly what the wizard runs, including the directory already
            // existing: the IDE creates it before the generator is asked.
            klioScaffold(
                path = dir.absolutePath,
                id = id,
                application = true,
                sampleCode = true,
                dependencies = listOf(
                    KlioDependencyChoice("kotlin.test"),
                    // A pack taken by feature, which is the shape the wizard's
                    // dropdown produces.
                    KlioDependencyChoice("kotlinx.serialization", listOf("json")),
                ),
            )
            val written = dir.walkTopDown().filter { it.isFile }.map { it.name }.toSet()
            val wanted = setOf(KLIO_MANIFEST, "Main.kt", "GreetingTest.kt")
            report("the wizard writes a manifest and its sample", written.containsAll(wanted), written.joinToString(", "))
            if (!written.containsAll(wanted)) failures++

            val modelJson = KlioCli.run(listOf("ide", "model", "--project", dir.absolutePath), dir)
            val scaffolded = KlioModelParser.parse(modelJson)
            report("the wizard's project models cleanly", scaffolded.problems.isEmpty(), scaffolded.problems.joinToString("; "))
            if (scaffolded.problems.isNotEmpty()) failures++

            // A dependency taken by feature has to run without the command line
            // repeating the feature: the manifest already asked for it.
            File(dir, "src/main/kotlin/Feature.kt").writeText(
                "package ${klioSamplePackage(id)}\n\n" +
                    "import kotlinx.serialization.json.Json\n\n" +
                    "fun encoded(): String = Json.encodeToString(listOf(1, 2, 3))\n"
            )
            val featureRun = KlioCli.run(
                listOf("run", "src/main/kotlin/Main.kt", "src/main/kotlin/Feature.kt"),
                dir,
            ).trim()
            report("a feature named in the manifest runs without a flag", featureRun == "hello, klio", featureRun)
            if (featureRun != "hello, klio") failures++

            val ran = KlioCli.run(listOf("run", "src/main/kotlin/Main.kt"), dir).trim()
            report("the wizard's program runs", ran == "hello, klio", ran)
            if (ran != "hello, klio") failures++

            val tested = KlioCli.run(listOf("test", dir.absolutePath), dir)
            val passed = "1 tests, 1 passed" in tested
            report("the wizard's test passes", passed, tested.lines().lastOrNull { it.isNotBlank() }.orEmpty())
            if (!passed) failures++
        } catch (e: Exception) {
            report("the wizard's project is usable", false, e.message ?: e.toString())
            failures++
        } finally {
            dir.deleteRecursively()
        }
        return failures
    }

    /** Paths, not PSI: an import invalidates every element held across it. */
    private fun collectKtPaths(project: Project, rootPath: String): List<String> =
        collectKtFiles(project, rootPath).mapNotNull { it.virtualFile?.path }

    private fun ktFile(project: Project, path: String): KtFile? {
        val file = LocalFileSystem.getInstance().refreshAndFindFileByPath(path) ?: return null
        return PsiManager.getInstance(project).findFile(file) as? KtFile
    }

    private fun collectKtFiles(project: Project, rootPath: String): List<KtFile> {
        val root = LocalFileSystem.getInstance().refreshAndFindFileByPath(rootPath) ?: return emptyList()
        val psiManager = PsiManager.getInstance(project)
        val out = ArrayList<KtFile>()
        VfsUtilCore.iterateChildrenRecursively(root, null) { file ->
            if (!file.isDirectory && file.extension == "kt") {
                (psiManager.findFile(file) as? KtFile)?.let { out.add(it) }
            }
            true
        }
        return out
    }

    private fun report(what: String, ok: Boolean, detail: String) {
        val status = if (ok) "OK  " else "FAIL"
        println("[selfcheck] $status $what${if (detail.isBlank()) "" else " — $detail"}")
    }
}
