// A typealias is transparent: every reference means the aliased type with the
// alias's type parameters substituted, in every syntactic position.

class Pair2<T1, T2>(val x1: T1, val x2: T2)
typealias ST<T> = Pair2<String, T>

class Cell<T>(val x: T)
typealias AliasedCell<TT> = Cell<TT>
typealias CStr = Cell<String>

typealias MyArray<T> = Array<T>
typealias BoolArray = Array<Boolean>
typealias IArray = IntArray

open class Base(private val s: String = "") {
    fun secret() = s
}
typealias B = Base
class Derived : B(s = "via-alias")

open class Box<T>(val value: T)
typealias BoxOf<T> = Box<T>
typealias BoxStr = Box<String>
class C1 : BoxOf<String>("header-generic")
class C2 : BoxStr("header-concrete")
val literal = object : BoxStr("object-literal") {}

class Holder {
    companion object {
        val result = "companion"
    }
}
typealias HolderCompanion = Holder.Companion

class Outer<T> {
    inner class Inner(val p: T)
    inner class Inner2<K>(val p: K)
    class Nested<N>(val p: N)

    typealias TAtoInner = Outer<String>.Inner
    typealias TAtoInner2<S> = Outer<String>.Inner2<S>
    typealias TAtoNested = Nested<String>

    fun fromInside(): String {
        val a = TAtoInner("inside")
        val b = TAtoInner2(7)
        val c = TAtoNested("nested")
        val ref = ::TAtoInner
        return a.p + "/" + b.p + "/" + c.p + "/" + ref("ref").p
    }
}

typealias InnerAlias<K> = Outer<K>.Inner
typealias InnerAlias2<K, K2> = Outer<K>.Inner2<K2>

typealias F<T, R> = T.() -> R
inline fun <T, R> T.myRun(f: F<T, R>) = f()

fun main() {
    val st = ST<String>("O", "K")
    println(st.x1 + st.x2)
    val cell = AliasedCell(42)
    println(cell.x)
    println(CStr("concrete").x)

    val ba = BoolArray(1) { true }
    val ia = IArray(2) { it * 10 }
    val ma = MyArray<Int>(3) { it + 1 }
    println("${ba[0]} ${ia.toList()} ${ma.toList()}")

    println(Derived().secret())
    println(C1().value + " " + C2().value + " " + literal.value)
    println(HolderCompanion.result)

    val outer = Outer<String>()
    println(outer.fromInside())
    println(outer.InnerAlias("top-level").p)
    println(outer.InnerAlias2<String, Int>(5).p)
    val bound = Outer<String>::InnerAlias
    println(bound(outer, "bound-ref").p)

    val suffix = "K"
    println("O".myRun { this + suffix })
}
