import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun make(): Flow<Int> {
    val r = flow { emit(1); emit(2) }   // builder call BEFORE the local
    val flow = flowOf(9)
    return if (flow === r) r else r
}
fun main() = runBlocking { println(make().toList()) }
