import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun other(): Flow<Int> { val flow = flowOf(9); return flow }
fun make(): Flow<Int> = flow { emit(1); emit(2) }   // no local in THIS fn
fun main() = runBlocking { println(make().toList() + other().toList()) }
