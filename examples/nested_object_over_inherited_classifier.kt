// A class's own nested classifier outranks a same-named classifier
// reachable through its supertypes: `Irrelevant.Key` and `Top.Key` are the
// nested `object Key`, not `kotlin.coroutines.CoroutineContext.Key`, so a
// context element keyed by its nested object is found under that key.
import kotlin.coroutines.*

class Holder {
    object Irrelevant : AbstractCoroutineContextElement(Key) {
        object Key : CoroutineContext.Key<Irrelevant>
    }
    fun run() {
        println(Irrelevant.Key::class.qualifiedName)
        println(Irrelevant.key === Irrelevant.Key)
        println((Irrelevant + EmptyCoroutineContext)[Irrelevant.Key] === Irrelevant)
    }
}

object Top : AbstractCoroutineContextElement(Key) {
    object Key : CoroutineContext.Key<Top>
}

// The same rule for a companion: `Key` in the superclass-constructor
// argument is the class's own `companion object Key`, so two element
// classes keep distinct keys and both survive in a combined context.
class DataElement(val data: Int) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<DataElement>
}
class OtherElement(val data: Int) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<OtherElement>
}

fun main() {
    Holder().run()
    println(Top.Key::class.qualifiedName)
    println(Top.key === Top.Key)
    println(Holder.Irrelevant.Key::class.qualifiedName)
    val combined = DataElement(1) + OtherElement(2)
    println(DataElement(1).key === OtherElement(2).key)
    println(combined.fold(0) { n, _ -> n + 1 })
    println(combined[DataElement]?.data)
    println(combined[OtherElement]?.data)
}
