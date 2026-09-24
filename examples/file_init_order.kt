// A file's top-level properties are initialized before its `main` runs, as
// the JVM initializes the class that declares `main` before launching it.
val greeting = run {
    println("file initialized")
    "hello"
}

fun twice(s: String) = s + s

fun main() {
    println("main starts")
    println(twice(greeting))
}
