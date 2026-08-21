fun main() {
    val a = HolderA()
    println(a.direct())
    println(a.ref())
    println(a.refInLambda())
    println(a.callInLambda())
    println(a.refAsArg())
    println(HolderB().use())
    println(HolderB().direct())
    println(HolderB().directBlock())
}
