// expect-error: T0013
interface A { fun f(): String }
interface C { fun f(): String = "C" }
class D : A, C
fun main() { println(D().f()) }
