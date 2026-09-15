package dev.klio.ide

import com.intellij.codeInsight.daemon.ProblemHighlightFilter
import com.intellij.openapi.module.ModuleUtilCore
import com.intellij.psi.PsiFile

/**
 * Materialised pack source is indexed, resolved and navigable, but never
 * highlighted. klio deliberately tolerates what the Kotlin frontend rejects (an
 * `expect` with no `actual` on a path nothing reaches, for one), and a library
 * a user cannot edit has no business painting their project red.
 */
class KlioHighlightFilter : ProblemHighlightFilter() {
    override fun shouldHighlight(file: PsiFile): Boolean {
        val project = file.project
        val state = KlioProjectState.getInstance(project)
        if (state.model == null) return true
        val module = ModuleUtilCore.findModuleForPsiElement(file) ?: return true
        return module.name !in state.libraryModuleNames()
    }

    override fun shouldProcessInBatch(file: PsiFile): Boolean = shouldHighlight(file)
}
