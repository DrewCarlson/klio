package dev.klio.ide

import com.intellij.execution.DefaultExecutionResult
import com.intellij.execution.ExecutionResult
import com.intellij.execution.Executor
import com.intellij.execution.configurations.CommandLineState
import com.intellij.execution.configurations.ConfigurationFactory
import com.intellij.execution.configurations.ConfigurationType
import com.intellij.execution.configurations.ConfigurationTypeBase
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.configurations.LocatableConfigurationBase
import com.intellij.execution.configurations.LocatableRunConfigurationOptions
import com.intellij.execution.configurations.RunConfiguration
import com.intellij.execution.configurations.RunConfigurationOptions
import com.intellij.execution.configurations.RunProfileState
import com.intellij.execution.configurations.RuntimeConfigurationError
import com.intellij.execution.filters.Filter
import com.intellij.execution.filters.OpenFileHyperlinkInfo
import com.intellij.execution.process.KillableColoredProcessHandler
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.process.ProcessTerminatedListener
import com.intellij.execution.runners.ExecutionEnvironment
import com.intellij.execution.runners.ProgramRunner
import com.intellij.execution.testframework.sm.SMTestRunnerConnectionUtil
import com.intellij.execution.testframework.sm.runner.SMTRunnerConsoleProperties
import com.intellij.execution.testframework.sm.runner.SMTestLocator
import com.intellij.openapi.options.SettingsEditor
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.IconLoader
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import java.io.File
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel

class KlioRunOptions : LocatableRunConfigurationOptions() {
    /** A `.kt` file, or a directory holding a `klio.toml`. Empty means the project. */
    private val targetProperty = string("").provideDelegate(this, "target")
    private val argumentsProperty = string("").provideDelegate(this, "arguments")
    private val testFilterProperty = string("").provideDelegate(this, "testFilter")

    var target: String
        get() = targetProperty.getValue(this) ?: ""
        set(value) = targetProperty.setValue(this, value)

    var arguments: String
        get() = argumentsProperty.getValue(this) ?: ""
        set(value) = argumentsProperty.setValue(this, value)

    var testFilter: String
        get() = testFilterProperty.getValue(this) ?: ""
        set(value) = testFilterProperty.setValue(this, value)
}

/** `run` executes a program, `test` drives the test tree off streamed events. */
enum class KlioCommand(val cliName: String) { RUN("run"), TEST("test") }

class KlioRunConfiguration(
    project: Project,
    factory: ConfigurationFactory,
    name: String,
    val command: KlioCommand,
) : LocatableConfigurationBase<KlioRunOptions>(project, factory, name) {

    public override fun getOptions(): KlioRunOptions = super.getOptions() as KlioRunOptions

    var target: String
        get() = options.target
        set(value) {
            options.target = value
        }

    var arguments: String
        get() = options.arguments
        set(value) {
            options.arguments = value
        }

    var testFilter: String
        get() = options.testFilter
        set(value) {
            options.testFilter = value
        }

    override fun getConfigurationEditor(): SettingsEditor<out RunConfiguration> = KlioSettingsEditor(command)

    override fun checkConfiguration() {
        if (KlioCli.findBinary() == null) {
            throw RuntimeConfigurationError("No klio binary found. Put `klio` on PATH or set it in Settings | Tools | KLIO.")
        }
    }

    override fun getState(executor: Executor, environment: ExecutionEnvironment): RunProfileState =
        KlioRunState(this, environment)

    fun buildCommandLine(): GeneralCommandLine {
        val binary = KlioCli.requireBinary()
        val workingDir = project.basePath?.let(::File) ?: File(".")
        val args = mutableListOf(command.cliName)
        val targetPath = target.ifBlank { workingDir.absolutePath }
        args += targetPath
        if (command == KlioCommand.TEST) {
            args += listOf("--format", "ij")
            if (testFilter.isNotBlank()) args += listOf("--filter", testFilter)
        }
        arguments.split(' ').filter { it.isNotBlank() }.forEach { args += it }
        return GeneralCommandLine(listOf(binary.absolutePath) + args)
            .withWorkingDirectory(workingDir.toPath())
            .withCharset(Charsets.UTF_8)
    }
}

private class KlioRunState(
    private val configuration: KlioRunConfiguration,
    environment: ExecutionEnvironment,
) : CommandLineState(environment) {

    init {
        // Stack frames and diagnostics print as `file.kt:line:col`, so make them links.
        addConsoleFilters(KlioSourceFilter(environment.project))
    }

    override fun startProcess(): ProcessHandler {
        val handler = KillableColoredProcessHandler(configuration.buildCommandLine())
        ProcessTerminatedListener.attach(handler)
        return handler
    }

    override fun execute(executor: Executor, runner: ProgramRunner<*>): ExecutionResult {
        if (configuration.command != KlioCommand.TEST) return super.execute(executor, runner)

        val handler = startProcess()
        val properties = KlioTestConsoleProperties(configuration, executor)
        val console = SMTestRunnerConnectionUtil.createAndAttachConsole("klio", handler, properties)
        console.addMessageFilter(KlioSourceFilter(environment.project))
        return DefaultExecutionResult(console, handler, *createActions(console, handler, executor))
    }
}

/** Carries the locator that turns a `klio://` hint into a source location. */
private class KlioTestConsoleProperties(
    configuration: KlioRunConfiguration,
    executor: Executor,
) : SMTRunnerConsoleProperties(configuration, "klio", executor) {
    init {
        isIdBasedTestTree = false
    }

    override fun getTestLocator(): SMTestLocator = KlioTestLocator()
}

private class KlioSettingsEditor(private val command: KlioCommand) : SettingsEditor<KlioRunConfiguration>() {
    private val target = JBTextField()
    private val arguments = JBTextField()
    private val filter = JBTextField()

    override fun resetEditorFrom(configuration: KlioRunConfiguration) {
        target.text = configuration.target
        arguments.text = configuration.arguments
        filter.text = configuration.testFilter
    }

    override fun applyEditorTo(configuration: KlioRunConfiguration) {
        configuration.target = target.text
        configuration.arguments = arguments.text
        configuration.testFilter = filter.text
    }

    override fun createEditor(): JComponent {
        val builder = FormBuilder.createFormBuilder()
            .addLabeledComponent("File or project directory:", target)
            .addLabeledComponent("Additional arguments:", arguments)
        if (command == KlioCommand.TEST) builder.addLabeledComponent("Test filter:", filter)
        return builder.panel ?: JPanel()
    }
}

class KlioRunConfigurationType : ConfigurationTypeBase(
    ID,
    "KLIO",
    "Run a Kotlin program on the klio interpreter",
    klioIcon(),
) {
    init {
        addFactory(KlioConfigurationFactory(this, KlioCommand.RUN, "KLIO"))
        addFactory(KlioConfigurationFactory(this, KlioCommand.TEST, "KLIO Test"))
    }

    companion object {
        const val ID = "KlioRunConfiguration"

        fun getInstance(): KlioRunConfigurationType =
            ConfigurationType.CONFIGURATION_TYPE_EP.findExtensionOrFail(KlioRunConfigurationType::class.java)

        fun factory(command: KlioCommand): ConfigurationFactory =
            getInstance().configurationFactories.first { (it as KlioConfigurationFactory).command == command }
    }
}

class KlioConfigurationFactory(
    type: ConfigurationTypeBase,
    val command: KlioCommand,
    private val label: String,
) : ConfigurationFactory(type) {
    override fun getId(): String = label
    override fun getName(): String = label
    override fun getOptionsClass(): Class<out RunConfigurationOptions> = KlioRunOptions::class.java
    override fun createTemplateConfiguration(project: Project): RunConfiguration =
        KlioRunConfiguration(project, this, label, command)
}

private fun klioIcon(): Icon = IconLoader.getIcon("/icons/klio.svg", KlioRunConfigurationType::class.java)

/** Turns `path/File.kt:12:5` in console output into a link. */
class KlioSourceFilter(private val project: Project) : Filter {
    private val pattern = Regex("([\\w./\\-]+\\.kt):(\\d+)(?::(\\d+))?")

    override fun applyFilter(line: String, entireLength: Int): Filter.Result? {
        val match = pattern.find(line) ?: return null
        val path = match.groupValues[1]
        val lineNumber = match.groupValues[2].toIntOrNull() ?: return null
        val column = match.groupValues.getOrNull(3)?.toIntOrNull() ?: 1
        val file = resolve(path) ?: return null
        val start = entireLength - line.length + match.range.first
        val hyperlink = OpenFileHyperlinkInfo(project, file, lineNumber - 1, (column - 1).coerceAtLeast(0))
        return Filter.Result(start, start + match.value.length, hyperlink)
    }

    private fun resolve(path: String): VirtualFile? {
        val fs = LocalFileSystem.getInstance()
        fs.findFileByPath(path)?.let { return it }
        val base = project.basePath ?: return null
        return fs.findFileByPath("$base/$path")
    }
}
