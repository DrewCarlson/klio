// Run with: klio run --include examples/run_resources examples/run_resources.kt
// A program's resources under `klio run`: the files `--include` names are
// read at the same mount paths its bundle would carry them at (the path
// relative to this file's directory), as a JVM program reads its classpath
// resources from a directory or its jar.
import klio.bundle.Resources

fun main() {
    println(Resources.list())
    println(Resources.readText("run_resources/greeting.txt").trim())
    println(Resources.readBytes("run_resources/notes.txt").size)
    println(Resources.exists("run_resources/notes.txt"))
    println(Resources.exists("run_resources/missing.txt"))
    try {
        Resources.readText("run_resources/missing.txt")
    } catch (e: IllegalArgumentException) {
        println("missing: ${e.message}")
    }
}
