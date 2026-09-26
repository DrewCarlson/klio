// A class's KClass names it as Kotlin does: a top-level or nested class has a
// simple and a qualified name, a local class (and a class nested in one) has
// a simple name and no qualified name, and an anonymous object's class has
// neither. Libraries rely on this: lifecycle's ViewModelProvider refuses a
// local class as a ViewModel because its qualifiedName is null.
package names

class TopLevel {
    class Nested
}

fun describe(label: String, simple: String?, qualified: String?) {
    println("$label: simpleName=$simple qualifiedName=$qualified")
}

fun main() {
    class Local {
        inner class Inner
    }
    val anonymous = object {}
    val fromLambda = run {
        class InLambda
        InLambda::class
    }

    describe("top-level", TopLevel::class.simpleName, TopLevel::class.qualifiedName)
    describe("nested", TopLevel.Nested::class.simpleName, TopLevel.Nested::class.qualifiedName)
    describe("local", Local::class.simpleName, Local::class.qualifiedName)
    describe("inner of local", Local.Inner::class.simpleName, Local.Inner::class.qualifiedName)
    describe("local in a lambda", fromLambda.simpleName, fromLambda.qualifiedName)
    describe("anonymous", anonymous::class.simpleName, anonymous::class.qualifiedName)
}
