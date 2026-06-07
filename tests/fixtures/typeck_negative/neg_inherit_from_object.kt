// expect-error: T0064
object O {
    fun greet(): String = "hi"
}
class D : O()
fun main() { println(D().greet()) }
