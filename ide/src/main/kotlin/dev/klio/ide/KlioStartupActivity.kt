package dev.klio.ide

import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity
import java.io.File

/** A project with a `klio.toml`, or any `.kt` file and a klio binary, syncs on open. */
class KlioStartupActivity : ProjectActivity {
    override suspend fun execute(project: Project) {
        val base = project.basePath ?: return
        if (!File(base, KLIO_MANIFEST).isFile) return

        // Editing a manifest raises the sync banner on it.
        EditorFactory.getInstance().eventMulticaster.addDocumentListener(
            KlioManifestListener(project),
            KlioProjectState.getInstance(project),
        )
        if (KlioCli.findBinary() == null) return
        // Deliberately not a Task.Backgroundable: a progress task started while
        // the project is still loading trips the platform's loading-state check
        // ("Should be called at least in the state COMPONENTS_LOADED"). A
        // ProjectActivity already runs off the EDT, so the work needs no task.
        KlioSyncAction.syncOnOpen(project)
    }
}
