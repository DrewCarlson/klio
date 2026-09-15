package dev.klio.ide

import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.service
import com.intellij.openapi.module.Module
import com.intellij.openapi.project.DumbService
import com.intellij.openapi.project.ModuleListener
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** The last model a sync produced, so run configurations and inspections read
 *  the same answer the workspace was built from. */
@Service(Service.Level.PROJECT)
class KlioProjectState : Disposable {
    @Volatile
    var model: KlioProjectModel? = null

    /** A manifest has been edited since the last import, so the model is behind. */
    @Volatile
    var manifestDirty: Boolean = false

    /** The installed packs a manifest can name, read once per sync. */
    @Volatile
    var packCatalogue: List<KlioPackInfo>? = null

    /** Guards against a second load while one is already in flight. */
    val catalogueLoading = AtomicBoolean(false)

    /** True while the importer itself is changing the module model. */
    @Volatile
    var importing: Boolean = false

    private val openSyncClaimed = AtomicBoolean(false)
    private val reimports = AtomicInteger(0)
    private var moduleWatch: Disposable? = null
    private var indexWatch: Disposable? = null

    /**
     * Calls [reapply] when something other than the importer removes one of the
     * modules it created. Bounded, so a platform that insists on removing them
     * cannot spin.
     */
    fun watchForDroppedModules(project: Project, expected: Set<String>, reapply: () -> Unit) {
        val watch = restartWatch(moduleWatch, "klio module watch").also { moduleWatch = it }
        project.messageBus.connect(watch).subscribe(
            ModuleListener.TOPIC,
            object : ModuleListener {
                override fun moduleRemoved(removedFrom: Project, module: Module) {
                    if (importing || module.name !in expected) return
                    if (reimports.incrementAndGet() > MAX_REIMPORTS) return
                    ApplicationManager.getApplication().executeOnPooledThread { reapply() }
                }
            },
        )
    }

    /**
     * Runs [action] after each of the next few indexing passes.
     *
     * No single edge identifies the rescan an import asks for: the import lands
     * either just before the previous dumb period ends or just after, so both
     * `runWhenSmart` and a one-shot on the next dumb exit can fire against the
     * pass before ours. A few passes covers either ordering, and the work is
     * only a cache drop and a redraw.
     */
    fun refreshWhenIndexed(project: Project, action: () -> Unit) {
        val watch = restartWatch(indexWatch, "klio index watch").also { indexWatch = it }
        val passes = AtomicInteger(0)
        project.messageBus.connect(watch).subscribe(
            DumbService.DUMB_MODE,
            object : DumbService.DumbModeListener {
                override fun exitDumbMode() {
                    val pass = passes.incrementAndGet()
                    if (pass > MAX_INDEX_REFRESHES) return
                    // Disposing a connection from inside its own callback, so the
                    // teardown waits for the dispatch to finish.
                    ApplicationManager.getApplication().invokeLater {
                        if (project.isDisposed) return@invokeLater
                        if (pass == MAX_INDEX_REFRESHES) {
                            Disposer.dispose(watch)
                            if (indexWatch === watch) indexWatch = null
                        }
                        action()
                    }
                }
            },
        )
    }

    /** True for the first caller only. Two activities can both see an empty
     *  model before either finishes, and the second import is pure waste. */
    fun claimOpenSync(): Boolean = openSyncClaimed.compareAndSet(false, true)

    fun libraryModuleNames(): Set<String> =
        model?.modules.orEmpty()
            .filter { it.highlighting == "off" }
            .map { KlioProjectImporter.moduleName(it.id) }
            .toSet()

    private fun restartWatch(current: Disposable?, name: String): Disposable {
        current?.let { Disposer.dispose(it) }
        return Disposer.newDisposable(name).also { Disposer.register(this, it) }
    }

    /** The listeners registered against this service unregister with the project. */
    override fun dispose() = Unit

    companion object {
        private const val MAX_REIMPORTS = 3
        private const val MAX_INDEX_REFRESHES = 3

        fun getInstance(project: Project): KlioProjectState = project.service()
    }
}
