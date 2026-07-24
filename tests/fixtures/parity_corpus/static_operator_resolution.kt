class NullableBox {
    operator fun plus(value: Int): String = "member:$value"
}

operator fun NullableBox?.plus(value: Int): String = "nullable:$value"

class GenericBox<String>(private val value: String) {
    fun get(): String = value
    fun literal(): kotlin.String = "qualified"
}

class Accumulator {
    operator fun plus(value: Int): String = "int:$value"
    operator fun plus(value: kotlin.String): String = "string:$value"
}

class BoundAccumulator {
    operator fun plus(value: Number): String = "number:$value"
    operator fun plus(value: CharSequence): String = "chars:$value"
}

class Word

class ExplicitBox<T : Number> {
    fun pick(value: T): String = "member"
}

fun ExplicitBox<Int>.pick(value: Word): String = "extension:constructor"

open class QualifiedParent<T>

class QualifiedChild<String> : QualifiedParent<kotlin.String>()

fun <T> QualifiedParent<T>.projected(value: T): T = value

class GenericScope<T : Number>(private val value: T) {
    fun kotlin.String.scopedValue(): T = value

    fun <T : CharSequence> shadowed(value: T): String =
        BoundAccumulator() + "$value".scopedValue()
}

class ShadowScope<T : Number> {
    fun choose(value: T): String = "class:$value"

    fun <T : CharSequence> run(value: T): String =
        this.choose(value)
}

fun <X : Number> ShadowScope<X>.choose(value: CharSequence): String =
    "extension:$value"

class InnerScope {
    fun String.towerTag(): String = "inner:$this"
}

class OuterScope {
    fun String.towerTag(): String = "outer:$this"

    fun run(): String = with(InnerScope()) {
        "receiver".towerTag()
    }
}

object LoopScope {
    private val offset: Int = 7

    fun Int.loopPick(): Int = this + offset
}

fun loopStaticMemberExtension(): Int = with(LoopScope) {
    var sum = 0
    for (value in 1..200) {
        sum += value.loopPick()
    }
    sum
}

fun main() {
    val nullable: NullableBox? = null
    println(nullable + 1)

    val box: GenericBox<Int> = GenericBox(2)
    println(Accumulator() + box.get())
    println(Accumulator() + box.literal())

    println((listOf(1) + sequenceOf(2)) + sequenceOf(3))

    val child: QualifiedChild<Int> = QualifiedChild()
    println(Accumulator() + child.projected("inherited"))

    val scope: GenericScope<Int> = GenericScope(4)
    println(with(scope) { Accumulator() + "receiver".scopedValue() })
    println(scope.shadowed("shadow"))
    println(ShadowScope<Int>().run("shadow"))
    println(OuterScope().run())
    println(sequenceOf(1, 2, 3).drop(1).drop(1).toList())
    println(ExplicitBox<Int>().pick(Word()))
    println(loopStaticMemberExtension())
}
