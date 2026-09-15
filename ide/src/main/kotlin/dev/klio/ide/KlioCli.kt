package dev.klio.ide

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.util.ExecUtil
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.components.service
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.project.Project
import java.io.File

class KlioCliException(message: String) : RuntimeException(message)

@Service(Service.Level.APP)
@State(name = "KlioSettings", storages = [Storage("klio.xml")])
class KlioSettings : PersistentStateComponent<KlioSettings.State> {
    data class State(var binaryPath: String = "")

    private var state = State()

    override fun getState(): State = state

    override fun loadState(loaded: State) {
        state = loaded
    }

    var binaryPath: String
        get() = state.binaryPath
        set(value) {
            state.binaryPath = value
        }

    companion object {
        fun getInstance(): KlioSettings = service()
    }
}

/**
 * Finds and drives the klio binary. Everything the IDE knows about a project
 * comes through here: the plugin never parses `klio.toml`, walks the pack
 * cache, or decodes a `.klio-pack`.
 */
object KlioCli {
    private val log = logger<KlioCli>()

    /** Where klio keeps packs, caches and the sources it materialises for the IDE. */
    fun dataHome(): File = File(System.getenv("KLIO_HOME") ?: System.getProperty("user.home"), ".klio")

    /** The configured binary, else one on PATH, else one in the klio data home. */
    fun findBinary(): File? {
        KlioSettings.getInstance().binaryPath.takeIf { it.isNotBlank() }?.let { configured ->
            val file = File(configured)
            if (file.canExecute()) return file
        }
        System.getenv("PATH")?.split(File.pathSeparator)?.forEach { dir ->
            val candidate = File(dir, "klio")
            if (candidate.canExecute()) return candidate
        }
        return File(dataHome(), "bin/klio").takeIf { it.canExecute() }
    }

    fun requireBinary(): File = findBinary() ?: throw KlioCliException(
        "no klio binary found. Put `klio` on PATH, or set its path in Settings | Tools | KLIO."
    )

    fun model(project: Project, refresh: Boolean = false): KlioProjectModel {
        val root = project.basePath ?: throw KlioCliException("the project has no directory on disk")
        val args = mutableListOf("ide", "model", "--project", root)
        if (refresh) args += "--refresh"
        val json = run(args, File(root))
        return KlioModelParser.parse(json)
    }

    /** Runs klio to completion and returns stdout, failing loudly on a non-zero exit. */
    fun run(args: List<String>, workingDir: File): String {
        // Waiting on a process while holding a read action, or on the UI thread,
        // freezes the IDE; the platform logs it and the call comes back empty.
        // Refusing here names the caller instead of leaving a silent hole.
        val app = ApplicationManager.getApplication()
        if (app != null && (app.isReadAccessAllowed || app.isDispatchThread)) {
            throw KlioCliException(
                "klio ${args.firstOrNull() ?: ""} was run on the UI thread or under a read action; " +
                    "load it in the background and read the result from there"
            )
        }
        val binary = requireBinary()
        val command = GeneralCommandLine(listOf(binary.absolutePath) + args)
            .withWorkingDirectory(workingDir.toPath())
            .withCharset(Charsets.UTF_8)
        log.info("klio " + args.joinToString(" "))
        val output = ExecUtil.execAndGetOutput(command)
        if (output.exitCode != 0) {
            throw KlioCliException(
                "klio ${args.joinToString(" ")} failed (exit ${output.exitCode})\n${output.stderr.trim()}"
            )
        }
        return output.stdout
    }

    /**
     * Runs klio from a context that may be the UI thread, which cannot wait on a
     * process. There the work goes to a background thread under a progress
     * dialog; anywhere else it runs directly.
     */
    fun runWithProgress(args: List<String>, workingDir: File, title: String, project: Project? = null): String {
        val app = ApplicationManager.getApplication()
        if (app == null || !app.isDispatchThread) return run(args, workingDir)

        var result: String? = null
        var failure: Exception? = null
        ProgressManager.getInstance().runProcessWithProgressSynchronously(
            {
                try {
                    result = run(args, workingDir)
                } catch (e: Exception) {
                    failure = e
                }
            },
            title,
            false,
            project,
        )
        failure?.let { throw it }
        return result ?: ""
    }

    /**
     * One line describing whether klio is usable and which one answered, for
     * the settings page. Blocking: call it off the UI thread.
     */
    fun describeStatus(): String {
        val binary = findBinary() ?: return "No klio binary found on PATH or in KLIO_HOME."
        return try {
            val version = run(listOf("--version"), binary.parentFile ?: File(".")).trim()
            "$version at ${binary.absolutePath}"
        } catch (e: Exception) {
            "Found ${binary.absolutePath}, but running it failed: ${e.message}"
        }
    }

    fun version(): String? = try {
        findBinary()?.let { run(listOf("--version"), it.parentFile ?: File(".")).trim() }
    } catch (e: Exception) {
        log.info("klio --version failed", e)
        null
    }
}
