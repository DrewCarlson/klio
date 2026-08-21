fun main() {
    val a = Alpha()
    println(a.direct())
    println(a.viaRef())
    println(a.fromLambda())
    println(a.refFromLambda())
    val b = Beta()
    println(b.direct())
    println(b.viaRef())
    println(b.fromLambda())
    println(b.refFromLambda())
}
