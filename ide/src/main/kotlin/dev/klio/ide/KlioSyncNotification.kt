package dev.klio.ide

import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.editor.event.DocumentListener
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileEditor
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.ui.EditorNotificationPanel
import com.intellij.ui.EditorNotificationProvider
import com.intellij.ui.EditorNotifications
import java.util.function.Function
import javax.swing.JComponent

const val KLIO_MANIFEST = "klio.toml"

/**
 * The banner across the top of a `klio.toml` that was edited since the last
 * import, with the sync it is asking for one click away. It is the same
 * affordance a Gradle build script carries, and for the same reason: the file
 * that decides what the project resolves against is the file you are looking at.
 */
class KlioSyncNotificationProvider : EditorNotificationProvider {
    override fun collectNotificationData(
        project: Project,
        file: VirtualFile,
    ): Function<in FileEditor, out JComponent?>? {
        if (file.name != KLIO_MANIFEST) return null
        if (project.basePath?.let { file.path.startsWith(it) } != true) return null

        val state = KlioProjectState.getInstance(project)
        val reason = when {
            state.model == null -> "This klio project has not been imported yet."
            state.manifestDirty -> "klio.toml has changed since the last sync."
            else -> return null
        }

        return Function { editor ->
            EditorNotificationPanel(editor, EditorNotificationPanel.Status.Info).apply {
                text = reason
                createActionLabel("Sync klio project") {
                    KlioSyncAction.syncInBackground(project, refresh = true)
                }
            }
        }
    }
}

/**
 * Marks the project as needing a sync while a manifest is being edited, so the
 * banner appears on the first keystroke rather than on save.
 */
class KlioManifestListener(private val project: Project) : DocumentListener {
    override fun documentChanged(event: DocumentEvent) {
        val file = FileDocumentManager.getInstance().getFile(event.document) ?: return
        if (file.name != KLIO_MANIFEST) return
        if (project.basePath?.let { file.path.startsWith(it) } != true) return
        val state = KlioProjectState.getInstance(project)
        if (state.manifestDirty) return
        state.manifestDirty = true
        EditorNotifications.getInstance(project).updateAllNotifications()
    }
}
