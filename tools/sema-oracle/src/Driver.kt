package klio.semaoracle

import org.jetbrains.kotlin.cli.common.ExitCode
import org.jetbrains.kotlin.cli.common.messages.CompilerMessageSeverity
import org.jetbrains.kotlin.cli.common.messages.CompilerMessageSourceLocation
import org.jetbrains.kotlin.cli.common.messages.MessageCollector
import org.jetbrains.kotlin.cli.jvm.K2JVMCompiler
import org.jetbrains.kotlin.config.Services
import java.io.File
import java.io.PrintStream
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.system.exitProcess

private const val USAGE = """usage: sema-oracle [options] <file.kt | dir>...
  -o <file>        write the TSV to <file> instead of stdout
  -cp <paths>      extra classpath entries (path-separator separated) for every compilation
  -j <n>           compile n files concurrently (default: half the cores, at most 4)
  --together       compile all the given files as one program (a multi-file
                   example); each file's sites are printed under its own path
  -X<flag>, -language-version <v>
                   passed through to every compilation (e.g. -Xname-based-destructuring=complete)
  --keep-failed    also emit the sites of files that failed to compile
  --jvm-names      keep JVM class names (java/util/ArrayList) instead of the Kotlin alias
  --debug          print raw FIR detail for every site to stderr
  --quiet          no progress/summary on stderr"""

/**
 * JVM-platform restrictions that leave resolution complete. A file whose only errors
 * are these still counts as compiled: the program is valid Kotlin outside the JVM.
 */
private val JVM_ONLY_ERRORS = setOf(
    "VALUE_CLASS_WITHOUT_JVM_INLINE_ANNOTATION",
)

private val DIAGNOSTIC_NAME = Regex("""^\[([A-Z][A-Z0-9_]+)]""")

private class FirstError : MessageCollector {
    var first: String? = null
    var errors = 0
    var frontendDone = false
    var jvmOnly = 0
    override fun clear() {}
    override fun hasErrors() = errors > 0
    override fun report(severity: CompilerMessageSeverity, message: String, location: CompilerMessageSourceLocation?) {
        if (!severity.isError) return
        if (message.contains(FrontendDone.MARKER)) {
            frontendDone = true
            return
        }
        val name = DIAGNOSTIC_NAME.find(message.lineSequence().first())?.groupValues?.get(1)
        if (name in JVM_ONLY_ERRORS) {
            jvmOnly++
            return
        }
        errors++
        if (first == null) {
            val where = location?.let { "${it.line}:${it.column}: " } ?: ""
            first = where + message.lineSequence().first()
        }
    }
}

private class Job(val display: String, val file: File)

/** One compilation: a file on its own, or every file of a program given with `--together`. */
private class Compilation(val jobs: List<Job>)

private class Result(val job: Job, val sites: List<Site>, val ok: Boolean, val error: String?, val unresolved: Int, val debug: List<String>)

fun main(argv: Array<String>) {
    var outFile: String? = null
    var classpath: String? = null
    var jobs = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(1, 4)
    var keepFailed = false
    var together = false
    var debug = false
    var quiet = false
    val passthrough = ArrayList<String>()
    val inputs = ArrayList<String>()
    var i = 0
    while (i < argv.size) {
        when (val a = argv[i]) {
            "-o" -> outFile = argv.getOrNull(++i)
            "-cp", "-classpath" -> classpath = argv.getOrNull(++i)
            "-j" -> jobs = argv.getOrNull(++i)?.toIntOrNull() ?: 1
            "--keep-failed" -> keepFailed = true
            "--together" -> together = true
            "--jvm-names" -> Options.commonNames = false
            "--debug" -> debug = true
            "--quiet" -> quiet = true
            "-h", "--help" -> { println(USAGE); return }
            "-language-version", "-api-version" -> { passthrough.add(a); argv.getOrNull(++i)?.let { passthrough.add(it) } }
            else -> if (a.startsWith("-X")) passthrough.add(a) else if (a.startsWith("-")) { System.err.println("unknown option $a\n$USAGE"); exitProcess(2) } else inputs.add(a)
        }
        i++
    }
    if (inputs.isEmpty()) { System.err.println(USAGE); exitProcess(2) }

    val work = ArrayList<Job>()
    for (input in inputs) {
        val f = File(input)
        when {
            f.isDirectory -> f.walk().filter { it.isFile && it.name.endsWith(".kt") }
                .map { it.relativeTo(f).path }.sorted()
                .forEach { rel -> work.add(Job(File(input, rel).path, File(f, rel))) }
            f.isFile -> work.add(Job(input, f))
            else -> System.err.println("[oracle-fail] $input: no such file")
        }
    }

    // One compilation per file: a path named twice (directly and through its directory) runs once.
    val unique = LinkedHashMap<String, Job>()
    for (job in work) unique.putIfAbsent(OracleSink.canonical(job.file.path), job)
    work.clear()
    work.addAll(unique.values)

    val home = kotlinHome()
    val pluginJar = File(OracleRegistrar::class.java.protectionDomain.codeSource.location.toURI()).path
    val scratch = Files.createTempDirectory("sema-oracle").toFile()
    System.setProperty("kotlin.environment.keepalive", "true")
    System.setProperty("idea.io.use.nio2", "true")

    val started = System.nanoTime()
    val units = if (together) listOf(Compilation(work.toList())) else work.map { Compilation(listOf(it)) }
    val pool = Executors.newFixedThreadPool(jobs.coerceAtLeast(1))
    val futures: List<Future<List<Result>>> = units.mapIndexed { n, unit ->
        pool.submit<List<Result>> { compile(unit, home, pluginJar, File(scratch, "o$n"), classpath, passthrough, debug) }
    }
    val results = futures.flatMap { it.get() }
    pool.shutdown()
    val elapsed = (System.nanoTime() - started) / 1e9

    val rows = ArrayList<Pair<String, Site>>()
    var failed = 0
    var unresolved = 0
    for (r in results) {
        r.debug.forEach { System.err.println("${r.job.display}: $it") }
        if (!r.ok) {
            failed++
            System.err.println("[oracle-fail] ${r.job.display}: ${r.error}")
        }
        unresolved += r.unresolved
        if (r.ok || keepFailed) r.sites.distinct().forEach { rows.add(r.job.display to it) }
    }
    rows.sortWith(compareBy<Pair<String, Site>>({ it.first }, { it.second.start }, { it.second.end }, { it.second.kind }, { it.second.target }))

    val sink: PrintStream = outFile?.let { PrintStream(File(it).outputStream().buffered(), false, "UTF-8") } ?: PrintStream(System.out, false, "UTF-8")
    for ((path, s) in rows) {
        sink.print(path); sink.print('\t'); sink.print(s.start); sink.print('\t'); sink.print(s.end); sink.print('\t')
        sink.print(s.kind); sink.print('\t'); sink.print(s.target); sink.print('\t'); sink.print(s.dispatch); sink.print('\t')
        sink.print(s.extension); sink.print('\n')
    }
    sink.flush()
    if (outFile != null) sink.close()
    scratch.deleteRecursively()
    if (!quiet) {
        System.err.println(
            "[oracle] ${work.size} files, ${work.size - failed} compiled, $failed failed, ${rows.size} sites, " +
                "$unresolved unresolved references skipped, %.1fs (%.1f files/s)".format(elapsed, work.size / elapsed)
        )
    }
}

private fun compile(
    unit: Compilation, home: File, pluginJar: String, outDir: File, classpath: String?, passthrough: List<String>, debug: Boolean,
): List<Result> {
    val collectors = ArrayList<FileCollector>()
    for (job in unit.jobs) {
        val bytes = try { job.file.readBytes() } catch (e: Exception) {
            return unit.jobs.map { Result(it, emptyList(), false, "cannot read ${job.display}: ${e.message}", 0, emptyList()) }
        }
        collectors.add(FileCollector(job.display, bytes, debug))
    }
    val keys = unit.jobs.map { OracleSink.canonical(it.file.path) }
    for ((key, collector) in keys.zip(collectors)) OracleSink.collectors[key] = collector
    val messages = FirstError()
    val code = try {
        val compiler = K2JVMCompiler()
        val args = compiler.createArguments()
        val argv = ArrayList<String>()
        unit.jobs.forEach { argv.add(it.file.path) }
        argv.addAll(listOf(
            "-d", outDir.path,
            "-kotlin-home", home.path,
            "-Xplugin=$pluginJar",
            "-Xuse-fir-lt=false",
            "-Xdisable-default-scripting-plugin",
            "-no-reflect",
            "-nowarn",
            "-Xsuppress-version-warnings",
            "-Xrender-internal-diagnostic-names",
        ))
        if (classpath != null) { argv.add("-classpath"); argv.add(classpath) }
        argv.addAll(passthrough)
        compiler.parseArguments(argv.toTypedArray(), args)
        compiler.exec(messages, Services.EMPTY, args)
    } catch (e: Throwable) {
        messages.first = messages.first ?: "compiler crashed: $e"
        ExitCode.INTERNAL_ERROR
    } finally {
        keys.forEach { OracleSink.collectors.remove(it) }
        outDir.deleteRecursively()
    }
    val compiled = messages.errors == 0 && (code == ExitCode.OK || messages.frontendDone || messages.jvmOnly > 0)
    return unit.jobs.zip(collectors).map { (job, collector) ->
        val ok = compiled && collector.visited
        val error = when {
            !compiled -> messages.first ?: code.name
            !collector.visited -> "plugin did not run"
            else -> null
        }
        Result(job, collector.sites, ok, error, collector.unresolved, collector.debugLines)
    }
}

private fun kotlinHome(): File {
    System.getProperty("sema.oracle.kotlin.home")?.let { return File(it) }
    val compilerJar = File(K2JVMCompiler::class.java.protectionDomain.codeSource.location.toURI())
    return compilerJar.parentFile.parentFile
}
