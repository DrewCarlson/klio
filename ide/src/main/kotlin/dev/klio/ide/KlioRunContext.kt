package dev.klio.ide

import com.intellij.execution.Location
import com.intellij.execution.PsiLocation
import com.intellij.execution.actions.ConfigurationContext
import com.intellij.execution.actions.LazyRunConfigurationProducer
import com.intellij.execution.configurations.ConfigurationFactory
import com.intellij.execution.lineMarker.ExecutorAction
import com.intellij.execution.lineMarker.RunLineMarkerContributor
import com.intellij.execution.testframework.sm.runner.SMTestLocator
import com.intellij.icons.AllIcons
import com.intellij.openapi.module.ModuleUtilCore
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Ref
import com.intellij.psi.PsiElement
import com.intellij.psi.search.GlobalSearchScope
import com.intellij.psi.util.PsiTreeUtil
import org.jetbrains.kotlin.idea.stubindex.KotlinClassShortNameIndex
import org.jetbrains.kotlin.idea.stubindex.KotlinTopLevelFunctionFqnNameIndex
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtClass
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.psiUtil.containingClass

/** `fun main` and `@Test` carry a gutter icon that runs them through klio. */
class KlioRunLineMarkerContributor : RunLineMarkerContributor() {
    override fun getInfo(element: PsiElement): Info? {
        if (element.node?.elementType != KtTokens.IDENTIFIER) return null
        val function = element.parent as? KtNamedFunction ?: return null
        if (!isKlioModule(function)) return null
        val icon = when {
            isTest(function) -> AllIcons.RunConfigurations.TestState.Run
            isMain(function) -> AllIcons.RunConfigurations.TestState.Run_run
            else -> return null
        }
        return Info(icon, ExecutorAction.getActions(0)) { "Run with klio" }
    }
}

internal fun isKlioModule(element: PsiElement): Boolean {
    val project = element.project
    val model = KlioProjectState.getInstance(project).model ?: return false
    val module = ModuleUtilCore.findModuleForPsiElement(element) ?: return false
    return model.modules.any { KlioProjectImporter.moduleName(it.id) == module.name && !it.isLibrary }
}

internal fun isTest(function: KtNamedFunction): Boolean =
    function.annotationEntries.any { it.shortName?.asString() == "Test" }

internal fun isMain(function: KtNamedFunction): Boolean =
    function.name == "main" && function.containingClass() == null

/** The function at the caret, which may be the element itself. */
internal fun enclosingFunction(element: PsiElement): KtNamedFunction? =
    PsiTreeUtil.getParentOfType(element, KtNamedFunction::class.java, false)

internal fun enclosingClass(element: PsiElement): KtClass? =
    PsiTreeUtil.getParentOfType(element, KtClass::class.java, false)

/** Builds a run configuration from whatever the user right-clicked. */
abstract class KlioConfigurationProducerBase(
    private val command: KlioCommand,
) : LazyRunConfigurationProducer<KlioRunConfiguration>() {

    override fun getConfigurationFactory(): ConfigurationFactory = KlioRunConfigurationType.factory(command)

    override fun setupConfigurationFromContext(
        configuration: KlioRunConfiguration,
        context: ConfigurationContext,
        sourceElement: Ref<PsiElement>,
    ): Boolean {
        val element = context.psiLocation ?: return false
        if (!isKlioModule(element)) return false
        val function = enclosingFunction(element)
        val file = element.containingFile?.virtualFile ?: return false

        when (command) {
            KlioCommand.RUN -> {
                if (function == null || !isMain(function)) return false
                configuration.target = file.path
                configuration.name = file.nameWithoutExtension
            }
            KlioCommand.TEST -> {
                val klass = enclosingClass(element)
                when {
                    function != null && isTest(function) -> {
                        val owner = function.containingClass()?.name
                        configuration.testFilter = if (owner != null) "$owner.${function.name}" else function.name.orEmpty()
                        configuration.name = configuration.testFilter
                    }
                    klass != null && klass.declarations.filterIsInstance<KtNamedFunction>().any(::isTest) -> {
                        configuration.testFilter = klass.name.orEmpty()
                        configuration.name = klass.name.orEmpty()
                    }
                    else -> return false
                }
                configuration.target = context.project.basePath ?: file.path
            }
        }
        return true
    }

    override fun isConfigurationFromContext(
        configuration: KlioRunConfiguration,
        context: ConfigurationContext,
    ): Boolean {
        val element = context.psiLocation ?: return false
        val function = enclosingFunction(element)
        return when (command) {
            KlioCommand.RUN ->
                function != null && isMain(function) &&
                    configuration.target == element.containingFile?.virtualFile?.path
            KlioCommand.TEST -> {
                val owner = function?.containingClass()?.name
                val expected = when {
                    function != null && isTest(function) && owner != null -> "$owner.${function.name}"
                    function != null && isTest(function) -> function.name.orEmpty()
                    else -> enclosingClass(element)?.name.orEmpty()
                }
                expected.isNotEmpty() && configuration.testFilter == expected
            }
        }
    }
}

class KlioRunConfigurationProducer : KlioConfigurationProducerBase(KlioCommand.RUN)

class KlioTestConfigurationProducer : KlioConfigurationProducerBase(KlioCommand.TEST)

/**
 * Resolves the `klio://Class.method` hints the test runner streams, so a node in
 * the test tree opens its source.
 */
class KlioTestLocator : SMTestLocator {
    override fun getLocation(
        protocol: String,
        path: String,
        project: Project,
        scope: GlobalSearchScope,
    ): List<Location<*>> {
        if (protocol != "klio") return emptyList()
        val className = path.substringBeforeLast('.', "")
        val member = path.substringAfterLast('.')

        if (className.isEmpty()) return topLevelFunction(project, scope, member)

        val classes = KotlinClassShortNameIndex.get(className, project, scope).filterIsInstance<KtClass>()
        for (klass in classes) {
            if (klass.name != className) continue
            val function = klass.declarations.filterIsInstance<KtNamedFunction>().firstOrNull { it.name == member }
            return listOf(PsiLocation.fromPsiElement(function ?: klass))
        }
        // `path` named a suite, not a method.
        val suite = KotlinClassShortNameIndex.get(path, project, scope).filterIsInstance<KtClass>().firstOrNull()
        return if (suite != null) listOf(PsiLocation.fromPsiElement(suite)) else emptyList()
    }

    private fun topLevelFunction(project: Project, scope: GlobalSearchScope, name: String): List<Location<*>> {
        val found = KotlinTopLevelFunctionFqnNameIndex.getAllKeys(project)
            .asSequence()
            .filter { it.substringAfterLast('.') == name }
            .flatMap { KotlinTopLevelFunctionFqnNameIndex.get(it, project, scope).asSequence() }
            .firstOrNull()
        return if (found != null) listOf(PsiLocation.fromPsiElement(found)) else emptyList()
    }
}
