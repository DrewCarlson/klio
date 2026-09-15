package dev.klio.ide

import com.intellij.ide.util.projectWizard.WizardContext
import com.intellij.ide.wizard.AbstractNewProjectWizardStep
import com.intellij.ide.wizard.GeneratorNewProjectWizard
import com.intellij.ide.wizard.NewProjectWizardBaseData.Companion.baseData
import com.intellij.ide.wizard.NewProjectWizardBaseStep
import com.intellij.ide.wizard.NewProjectWizardChainStep.Companion.nextStep
import com.intellij.ide.wizard.NewProjectWizardStep
import com.intellij.ide.wizard.RootNewProjectWizardStep
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.openapi.ui.popup.JBPopupListener
import com.intellij.openapi.ui.popup.LightweightWindowEvent
import com.intellij.openapi.util.IconLoader
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.ui.CheckBoxList
import com.intellij.ui.components.ActionLink
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.panels.VerticalLayout
import com.intellij.ui.dsl.builder.AlignX
import com.intellij.ui.dsl.builder.Panel
import com.intellij.ui.dsl.builder.bindSelected
import com.intellij.ui.dsl.builder.bindText
import com.intellij.util.ui.JBUI
import java.awt.Component
import java.awt.Dimension
import java.awt.FlowLayout
import java.io.File
import javax.swing.Icon
import javax.swing.JPanel

/**
 * New Project | KLIO.
 *
 * The scaffolding itself is `klio pack new`, so what a project looks like stays
 * defined in one place. The wizard adds what the CLI has no opinion about: which
 * of the installed packs to depend on, and whether to write a program or a
 * library.
 */
class KlioNewProjectWizard : GeneratorNewProjectWizard {
    override val id: String get() = "klio"
    override val name: String get() = "KLIO"
    override val icon: Icon get() = klioProjectIcon()
    override val description: String
        get() = "A Kotlin project that runs on the klio interpreter, with no JVM, Gradle or kotlinc."

    override fun createStep(context: WizardContext): NewProjectWizardStep =
        RootNewProjectWizardStep(context)
            .nextStep(::NewProjectWizardBaseStep)
            .nextStep(::KlioNewProjectStep)
}

private class KlioNewProjectStep(parent: NewProjectWizardBaseStep) : AbstractNewProjectWizardStep(parent) {

    private val libraryIdProperty = propertyGraph.property("")
    private val applicationProperty = propertyGraph.property(true)
    private val sampleCodeProperty = propertyGraph.property(true)
    private val selected = LinkedHashMap<String, Boolean>()

    /** Chosen features per pack. Absent or empty means whatever the pack makes default. */
    private val features = LinkedHashMap<String, MutableList<String>>()
    private val dependencies = JPanel(VerticalLayout(0))

    /**
     * A fixed viewport, so neither a long pack id nor a home full of packs
     * decides how wide or tall the wizard is.
     */
    private val dependenciesView = JBScrollPane(dependencies).apply {
        preferredSize = Dimension(420, 150)
        border = JBUI.Borders.empty()
    }

    private var libraryId by libraryIdProperty
    private var application by applicationProperty
    private var sampleCode by sampleCodeProperty

    override fun setupUI(builder: Panel) {
        // A library id defaults to the project name, which is what a user
        // would type anyway.
        libraryId = baseData?.name.orEmpty()
        baseData?.nameProperty?.afterChange { if (libraryId.isBlank() || libraryId == it) libraryId = it }

        builder.row("Library id:") {
            textField()
                .bindText(libraryIdProperty)
                .align(AlignX.FILL)
                .comment("Globally unique, like <code>com.example.app</code>.")
        }
        builder.row {
            checkBox("Application (declares main)").bindSelected(applicationProperty)
        }
        builder.row {
            checkBox("Add sample code and a test").bindSelected(sampleCodeProperty)
        }

        builder.group("Dependencies") {
            row {
                cell(dependenciesView).align(AlignX.FILL)
            }
        }
        loadDependencies()
    }

    /**
     * The catalogue comes from running klio, and a wizard step is built on the
     * UI thread, so the list fills in when the answer arrives. Reading it inline
     * is what made every project look like it had no packs available.
     */
    private fun loadDependencies() {
        dependencies.add(JBLabel("Reading installed packs..."))
        ApplicationManager.getApplication().executeOnPooledThread {
            val packs = try {
                KlioPackCatalogueReader.load(null)
            } catch (e: Exception) {
                LOG.info("klio: the pack catalogue is unavailable in the wizard", e)
                emptyList()
            }
            ApplicationManager.getApplication().invokeLater({ showDependencies(packs) }, ModalityState.any())
        }
    }

    private fun showDependencies(packs: List<KlioPackInfo>) {
        dependencies.removeAll()
        if (packs.isEmpty()) {
            dependencies.add(JBLabel("No packs installed. The project depends on the stdlib."))
        } else {
            for (pack in packs) dependencies.add(dependencyRow(pack))
        }
        dependencies.revalidate()
        dependencies.repaint()
    }

    /**
     * A pack, and for one that has features, the way to take only some of them.
     * The link stays disabled until the pack is chosen, since features of a
     * dependency you are not taking mean nothing.
     */
    private fun dependencyRow(pack: KlioPackInfo): JPanel {
        val row = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), 0))
        val box = JBCheckBox("${pack.id}  ${pack.version}", pack.id == "kotlin.test")
        selected[pack.id] = box.isSelected
        row.add(box)

        if (pack.features.isEmpty()) {
            box.addActionListener { selected[pack.id] = box.isSelected }
            return row
        }

        val chooser = ActionLink(featureSummary(pack))
        chooser.isEnabled = box.isSelected
        chooser.addActionListener {
            showFeaturePopup(pack, chooser) { chooser.text = featureSummary(pack) }
        }
        box.addActionListener {
            selected[pack.id] = box.isSelected
            chooser.isEnabled = box.isSelected
        }
        row.add(chooser)
        return row
    }

    /** Before a choice is made the pack's defaults apply, and the popup marks which those are. */
    private fun featureSummary(pack: KlioPackInfo): String {
        val chosen = features[pack.id].orEmpty()
        if (chosen.isEmpty()) return "features"
        return chosen.joinToString(", ")
    }

    /** A dropdown of the pack's features, each with what it requires. */
    private fun showFeaturePopup(pack: KlioPackInfo, anchor: Component, onClosed: () -> Unit) {
        val list = CheckBoxList<String>()
        val chosen = features[pack.id].orEmpty().toSet()
        for (feature in pack.features) {
            val notes = buildList {
                if (feature.name in pack.defaultFeatures) add("default")
                if (feature.requires.isNotEmpty()) add("requires ${feature.requires.joinToString(", ")}")
            }
            val label = feature.name + if (notes.isEmpty()) "" else "  (${notes.joinToString("; ")})"
            // A default is ticked to start with, so leaving the popup alone
            // keeps what the pack would have done anyway.
            val ticked = if (chosen.isEmpty()) feature.name in pack.defaultFeatures else feature.name in chosen
            list.addItem(feature.name, label, ticked)
        }
        val popup = JBPopupFactory.getInstance()
            .createComponentPopupBuilder(JBScrollPane(list), list)
            .setRequestFocus(true)
            .setTitle("Features of ${pack.id}")
            .setResizable(true)
            .setMinSize(Dimension(260, 120))
            .createPopup()
        popup.addListener(object : JBPopupListener {
            override fun onClosed(event: LightweightWindowEvent) {
                val picked = pack.features.map { it.name }.filterIndexed { index, _ -> list.isItemSelected(index) }
                // Picking exactly the defaults is the same as picking nothing,
                // and saying nothing is what lets the pack change its mind.
                features[pack.id] = if (picked.toSet() == pack.defaultFeatures.toSet()) {
                    mutableListOf()
                } else {
                    picked.toMutableList()
                }
                onClosed()
            }
        })
        popup.showUnderneathOf(anchor)
    }

    override fun setupProject(project: Project) {
        val base = baseData ?: return
        val path = File(base.path, base.name).path
        val id = libraryId.ifBlank { base.name }.ifBlank { "com.example.app" }
        try {
            klioScaffold(
                path = path,
                id = id,
                application = application,
                sampleCode = sampleCode,
                dependencies = selected.filterValues { it }.keys.map {
                    KlioDependencyChoice(it, features[it].orEmpty().toList())
                },
                project = project,
            )
            LocalFileSystem.getInstance().refreshAndFindFileByPath(path)?.refresh(false, true)
        } catch (e: Exception) {
            LOG.warn("klio: scaffolding $path failed", e)
            NotificationGroupManager.getInstance()
                .getNotificationGroup("KLIO")
                .createNotification("klio project not scaffolded", e.message ?: e.toString(), NotificationType.ERROR)
                .notify(project)
        }
    }

    private companion object {
        val LOG = logger<KlioNewProjectStep>()
    }
}

internal fun klioProjectIcon(): Icon =
    IconLoader.getIcon("/icons/klio.svg", KlioNewProjectWizard::class.java)

/**
 * Writes a klio project: the manifest, and the sample if one was asked for.
 * `pack new` lays down the directory layout, so what a project looks like stays
 * defined by the CLI, and this adds what the wizard collected.
 */
internal fun klioScaffold(
    path: String,
    id: String,
    application: Boolean,
    sampleCode: Boolean,
    dependencies: List<KlioDependencyChoice>,
    project: Project? = null,
) {
    val parent = File(path).parentFile ?: File(".")
    KlioCli.runWithProgress(listOf("pack", "new", path, "--id", id), parent, "Creating klio project", project)

    File(path, KLIO_MANIFEST).writeText(klioManifest(id, application, sampleCode, dependencies))
    if (!sampleCode) return

    val pkg = klioSamplePackage(id)
    File(path, "src/main/kotlin").mkdirs()
    File(path, "src/main/kotlin/Main.kt").writeText(klioSampleMain(pkg))
    if (dependencies.none { it.id == "kotlin.test" }) return
    File(path, "src/test/kotlin").mkdirs()
    File(path, "src/test/kotlin/GreetingTest.kt").writeText(klioSampleTest(pkg))
}

/** A dependency as the wizard collected it: a pack, and which of its features. */
internal data class KlioDependencyChoice(val id: String, val features: List<String> = emptyList())

/**
 * The manifest the wizard writes. `pack new` scaffolds one with the stdlib
 * alone; this is the rest of what the wizard was asked for, in the one-line-per
 * dependency form a manifest uses. A dependency with chosen features spells
 * them out, and one without takes whatever the pack makes default.
 */
internal fun klioManifest(
    id: String,
    application: Boolean,
    sampleCode: Boolean,
    dependencies: List<KlioDependencyChoice>,
): String = buildString {
    append("[library]\n")
    append("id = \"$id\"\n")
    append("version = \"0.1.0\"\n")
    append("abi = 1\n")
    append("source_roots = [\"src/main/kotlin\"]\n\n")
    if (application) {
        append("[application]\n")
        append("main = \"src/main/kotlin/Main.kt\"\n\n")
    }
    append("[deps]\n")
    append("stdlib = \"*\"\n")
    for (dependency in dependencies) {
        if (dependency.features.isEmpty()) {
            append("\"${dependency.id}\" = \"*\"\n")
        } else {
            val features = dependency.features.joinToString(", ") { "\"$it\"" }
            append("\"${dependency.id}\" = { version = \"*\", features = [$features] }\n")
        }
    }
    if (sampleCode && dependencies.any { it.id == "kotlin.test" }) {
        append("\n[[test]]\n")
        append("root = \"src/test/kotlin\"\n")
    }
}

/** A package name an id can always produce: dashes are not Kotlin identifiers. */
internal fun klioSamplePackage(id: String): String =
    id.split('.').filter { it.isNotBlank() }.joinToString(".") { it.replace('-', '_') }

internal fun klioSampleMain(pkg: String): String =
    """
    package $pkg

    fun greeting(name: String): String = "hello, ${'$'}name"

    fun main() {
        println(greeting("klio"))
    }

    """.trimIndent()

internal fun klioSampleTest(pkg: String): String =
    """
    package $pkg

    import kotlin.test.Test
    import kotlin.test.assertEquals

    class GreetingTest {
        @Test
        fun greets() {
            assertEquals("hello, klio", greeting("klio"))
        }
    }

    """.trimIndent()
