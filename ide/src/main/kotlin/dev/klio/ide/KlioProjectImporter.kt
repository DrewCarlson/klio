package dev.klio.ide

import com.intellij.codeInsight.daemon.DaemonCodeAnalyzer
import com.intellij.facet.FacetManager
import com.intellij.ide.projectView.ProjectView
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.module.Module
import com.intellij.openapi.module.ModuleManager
import com.intellij.openapi.module.ModuleTypeManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.project.RootsChangeRescanningInfo
import com.intellij.openapi.roots.ModifiableRootModel
import com.intellij.openapi.roots.ModuleOrderEntry
import com.intellij.openapi.roots.ModuleRootManager
import com.intellij.openapi.roots.ex.ProjectRootManagerEx
import com.intellij.openapi.util.EmptyRunnable
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.psi.PsiManager
import com.intellij.ui.EditorNotifications
import org.jetbrains.kotlin.analysis.api.KaPlatformInterface
import org.jetbrains.kotlin.analysis.api.platform.modification.KotlinGlobalModuleStateModificationEvent
import org.jetbrains.kotlin.analysis.api.platform.modification.KotlinModificationEvent
import org.jetbrains.kotlin.cli.common.arguments.K2MetadataCompilerArguments
import org.jetbrains.kotlin.config.CompilerSettings
import org.jetbrains.kotlin.idea.facet.KotlinFacet
import org.jetbrains.kotlin.idea.facet.KotlinFacetType
import org.jetbrains.kotlin.platform.CommonPlatforms
import java.io.File
import java.nio.file.Path
import kotlin.concurrent.withLock

/**
 * Turns the model `klio ide model` prints into IntelliJ modules, content roots,
 * dependencies and Kotlin facets. This is the whole of the IDE integration's
 * project-model work: the official Kotlin plugin does every piece of analysis
 * over the modules built here.
 *
 * Packs are modules rather than libraries because a library resolves nothing
 * when its roots hold Kotlin source instead of compiled output, which is all
 * klio has to offer. Measured, not assumed.
 */
object KlioProjectImporter {
    private val log = logger<KlioProjectImporter>()

    private const val MAX_IMPORT_ATTEMPTS = 3
    private const val IMPORT_SETTLE_MS = 2000L

    /** Generated `.iml` files live here, so a stale module is recognisable. */
    private fun moduleDir(project: Project): Path =
        Path.of(project.basePath ?: ".", ".idea", "klio-modules")

    /** Two syncs racing would commit the module model twice and leave the file
     *  index rebuilding under the second commit, so they queue instead. */
    private val syncLock = java.util.concurrent.locks.ReentrantLock()

    /** The first sync after a project opens, whoever gets there first. A later
     *  caller through [sync] still re-imports; this only collapses the race
     *  between opening the project and whatever asked for a model straight away. */
    fun syncOnOpen(project: Project, refresh: Boolean = false): KlioProjectModel? {
        if (!KlioProjectState.getInstance(project).claimOpenSync()) return null
        return sync(project, refresh)
    }

    fun sync(project: Project, refresh: Boolean = false): KlioProjectModel = syncLock.withLock {
        val model = KlioCli.model(project, refresh)
        applyAndConfirm(project, model)
        val state = KlioProjectState.getInstance(project)
        state.model = model
        state.manifestDirty = false
        // A sync is the moment a pack may have been installed or removed, and it
        // runs off the UI thread, so the catalogue completion needs is loaded
        // here rather than on the read action that will ask for it.
        state.packCatalogue = null
        state.packCatalogue = try {
            KlioPackCatalogueReader.load(project)
        } catch (e: Exception) {
            log.info("klio ide packs failed", e)
            null
        }
        EditorNotifications.getInstance(project).updateAllNotifications()
        model
    }

    /**
     * Imports, and puts back what the platform takes away. A delayed
     * synchroniser reconciles the cached workspace a few seconds after a project
     * opens and silently discards an import that landed first. Waiting a fixed
     * time races it, so this listens for its own modules being removed instead.
     */
    private fun applyAndConfirm(project: Project, model: KlioProjectModel) {
        val state = KlioProjectState.getInstance(project)
        state.watchForDroppedModules(project, model.modules.map { moduleName(it.id) }.toSet()) {
            reapply(project, model)
        }
        reapply(project, model)
    }

    private fun reapply(project: Project, model: KlioProjectModel) {
        val state = KlioProjectState.getInstance(project)
        state.importing = true
        try {
            ApplicationManager.getApplication().invokeAndWait {
                ApplicationManager.getApplication().runWriteAction {
                    apply(project, model)
                }
            }
        } finally {
            state.importing = false
        }
        saveWorkspace(project)
    }

    /**
     * The module model lives in memory until the store writes it, and a reload
     * before that sees an empty workspace.
     *
     * This must run outside the write action that built the model: on the EDT
     * `ProjectImpl.save` opens a modal progress and pumps the event queue, so a
     * save under the write lock waits on a lock it holds itself and hangs on an
     * empty progress dialog. Off the EDT it simply blocks and returns.
     */
    private fun saveWorkspace(project: Project) {
        val app = ApplicationManager.getApplication()
        if (app.isDispatchThread || app.isWriteAccessAllowed) {
            app.executeOnPooledThread { if (!project.isDisposed) project.save() }
            return
        }
        if (!project.isDisposed) project.save()
    }

    private fun apply(project: Project, model: KlioProjectModel) {
        val dir = moduleDir(project)
        File(dir.toString()).mkdirs()

        val moduleManager = ModuleManager.getInstance(project)
        val modifiable = moduleManager.getModifiableModel()
        val byId = HashMap<String, Module>()

        // A pack that declares `expect` needs two modules with a dependsOn edge
        // between them, because the frontend only pairs an expect with an actual
        // across that edge. Those two belong under one node in the Project view,
        // not beside each other as if they were separate dependencies.
        val split = model.modules
            .filter { it.isLibrary }
            .groupBy { packOf(it.id) }
            .filterValues { it.size > 1 }
            .keys

        try {
            // Every module first, so a dependency can name one declared later.
            for (entry in model.modules) {
                val name = moduleName(entry.id)
                val existing = modifiable.findModuleByName(name)
                val module = existing ?: modifiable.newModule(
                    dir.resolve("$name.iml").toString(),
                    ModuleTypeManager.getInstance().defaultModuleType.id,
                )
                val pack = packOf(entry.id)
                if (entry.isLibrary && pack in split) {
                    // Replaced upstream by grouping on qualified module names,
                    // which is a user-facing setting rather than ours to set.
                    @Suppress("DEPRECATION")
                    modifiable.setModuleGroupPath(module, arrayOf(pack))
                }
                byId[entry.id] = module
            }

            // Modules we generated on an earlier sync that the model dropped.
            for (module in modifiable.modules) {
                if (byId.values.any { it.name == module.name }) continue
                if (!module.moduleFilePath.startsWith(dir.toString())) continue
                modifiable.disposeModule(module)
            }

            modifiable.commit()
        } catch (e: Throwable) {
            modifiable.dispose()
            throw e
        }

        for (entry in model.modules) {
            val module = byId[entry.id] ?: continue
            configureRoots(module, entry, byId)
            configureFacet(module, entry, byId, model)
        }
        invalidateCaches(project)
        log.info("klio: ${model.modules.size} modules imported")
    }

    /**
     * A file the editor already opened was analysed before its module existed,
     * and that answer outlives the import unless the caches that hold it are
     * told the module structure changed. Without this, a project opened from
     * cold resolves nothing until the user syncs a second time by hand.
     */
    @OptIn(KaPlatformInterface::class)
    private fun invalidateCaches(project: Project) {
        // Armed before the roots change, because that is what starts the pass
        // this waits on.
        KlioProjectState.getInstance(project).refreshWhenIndexed(project) {
            log.info("klio: refreshing after an indexing pass")
            PsiManager.getInstance(project).dropPsiCaches()
            DaemonCodeAnalyzer.getInstance(project).restart("klio project import")
            // The Project view keeps the tree it computed before the import,
            // packs and all, until it is asked to build it again.
            ProjectView.getInstance(project).refresh()
        }

        ProjectRootManagerEx.getInstanceEx(project)
            .makeRootsChange(EmptyRunnable.getInstance(), RootsChangeRescanningInfo.TOTAL_RESCAN)
        project.messageBus
            .syncPublisher(KotlinModificationEvent.TOPIC)
            .onModification(KotlinGlobalModuleStateModificationEvent)
        PsiManager.getInstance(project).dropPsiCaches()
        DaemonCodeAnalyzer.getInstance(project).restart("klio project import")
    }

    private fun configureRoots(module: Module, entry: KlioModule, byId: Map<String, Module>) {
        val rootModel: ModifiableRootModel = ModuleRootManager.getInstance(module).modifiableModel
        try {
            // klio has no JDK, so neither do its modules. A module that inherits
            // the project's would put `java.*` in scope for a program that
            // cannot use it, and show the JDK among the project's libraries.
            rootModel.sdk = null

            for (existing in rootModel.contentEntries) rootModel.removeContentEntry(existing)
            for (orderEntry in rootModel.orderEntries) {
                if (orderEntry is ModuleOrderEntry) rootModel.removeOrderEntry(orderEntry)
            }

            for (path in entry.contentRoots) {
                val file = refresh(path) ?: continue
                val content = rootModel.addContentEntry(file)
                content.addSourceFolder(file, entry.isTest)
            }

            // A refinement edge is also a plain dependency: the actualising module
            // reads the declarations it actualises.
            for (dependencyId in entry.dependsOn + entry.dependencies) {
                val target = byId[dependencyId] ?: continue
                if (target == module) continue
                val order = rootModel.addModuleOrderEntry(target)
                order.isExported = true
            }
            rootModel.commit()
        } catch (e: Throwable) {
            rootModel.dispose()
            throw e
        }
    }

    private fun configureFacet(
        module: Module,
        entry: KlioModule,
        byId: Map<String, Module>,
        model: KlioProjectModel,
    ) {
        val facetManager = FacetManager.getInstance(module)
        val facetModel = facetManager.createModifiableModel()
        val existing = facetManager.getFacetByType(KotlinFacetType.TYPE_ID)
        val facet: KotlinFacet = existing ?: run {
            val type = KotlinFacetType.INSTANCE
            val created = facetManager.createFacet(type, type.defaultFacetName, type.createDefaultConfiguration(), null)
            facetModel.addFacet(created)
            created
        }

        val settings = facet.configuration.settings
        settings.useProjectSettings = false
        // Fully initialised arguments keep the facet off the Kotlin plugin's
        // default-platform path, which resolves a runtime library version
        // through a fixed set of platform kinds and rejects anything else.
        settings.compilerArguments = K2MetadataCompilerArguments().apply {
            languageVersion = model.languageVersion
            apiVersion = model.languageVersion
            multiPlatform = true
            freeArgs = emptyList()
        }
        // Both klio and expect-bearing roots analyse as common. A klio-specific
        // platform kind is registrable but not usable: the Kotlin plugin's
        // IdePlatformKindProjectStructure switches over a fixed set of kinds and
        // throws for anything else, and getDefaultTargetPlatform walks every
        // registered kind, so one extra kind breaks facet defaults IDE-wide.
        settings.targetPlatform = CommonPlatforms.defaultCommonPlatform
        settings.compilerSettings = CompilerSettings().apply {
            additionalArguments = entry.compilerArguments.joinToString(" ")
        }
        settings.dependsOnModuleNames = entry.dependsOn.mapNotNull { byId[it]?.name }
        settings.pureKotlinSourceFolders = entry.contentRoots
        settings.isTestModule = entry.isTest
        settings.isHmppEnabled = true

        facetModel.commit()
    }

    private fun refresh(path: String): VirtualFile? {
        val file = LocalFileSystem.getInstance().refreshAndFindFileByPath(path)
        if (file == null) log.warn("klio: content root missing on disk: $path")
        return file
    }

    /** IntelliJ module names keep `:` and `/` out of the way. */
    fun moduleName(id: String): String = id.replace('/', '.').replace(':', '.')

    /** The pack a module id belongs to: `stdlib:common` and `stdlib` are both `stdlib`. */
    private fun packOf(id: String): String = id.substringBefore(':')
}
