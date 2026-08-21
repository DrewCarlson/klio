import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val g = (0..3).asFlow().onEach { }
    val c = g.cancellable()
    println("g=" + g::class.simpleName + " c=" + c::class.simpleName + " same=" + (g === c))
    val sf = flow { emit(1) }
    println("sf=" + sf::class.simpleName + " sfc=" + sf.cancellable()::class.simpleName)
}
