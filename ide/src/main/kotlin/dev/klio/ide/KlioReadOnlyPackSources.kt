package dev.klio.ide

import com.intellij.openapi.fileEditor.impl.NonProjectFileWritingAccessExtension
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile

/**
 * Materialised pack sources are a view of the pack, not the source of truth: an
 * edit changes nothing about what runs and the next materialisation overwrites
 * it. The model marks these modules `readOnly`; this enforces it, so the editor
 * refuses the edit rather than quietly discarding it later.
 */
class KlioReadOnlyPackSources(private val project: Project) : NonProjectFileWritingAccessExtension {

    override fun isNotWritable(file: VirtualFile): Boolean {
        val state = KlioProjectState.getInstance(project)
        state.model?.let { model ->
            for (entry in model.modules) {
                if (!entry.readOnly) continue
                for (root in entry.contentRoots) {
                    if (file.path == root || file.path.startsWith("$root/")) return true
                }
            }
        }
        // Before the first sync there is no model, and the materialisation
        // directory is a fixed path, so it can answer on its own.
        return file.path.startsWith(materialisationRoot)
    }

    private val materialisationRoot: String by lazy { "${KlioCli.dataHome()}/ide/libs" }
}
