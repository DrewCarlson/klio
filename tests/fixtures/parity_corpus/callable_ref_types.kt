import kotlin.reflect.KCallable
import kotlin.reflect.KClass
import kotlin.reflect.KFunction
import kotlin.reflect.KProperty

class Box(val v: Int)

fun greet(x: Int): String = "n=$x"

fun main() {
    val pref = Box::v
    val fref = ::greet
    println(pref is KProperty<*>)
    println(pref is KCallable<*>)
    println(fref is KFunction<*>)
    println(fref is KCallable<*>)
    println(Box::class is KClass<*>)
}
