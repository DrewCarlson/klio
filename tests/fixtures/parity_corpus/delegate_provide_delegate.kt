// Spec ch.9: `provideDelegate` is called once at property-init time and
// its result becomes the stored delegate. Here `Factory.provideDelegate`
// produces a `Holder` whose `getValue` returns the validated constant.

import kotlin.reflect.KProperty

class Holder(val v: Int) {
    operator fun getValue(thisRef: Any?, prop: KProperty<*>): Int = v
}

class Factory(val base: Int) {
    operator fun provideDelegate(thisRef: Any?, prop: KProperty<*>): Holder {
        if (prop.name != "x") error("unexpected property: ${prop.name}")
        return Holder(base + 1)
    }
}

class Owner {
    val x: Int by Factory(10)
}

fun main() {
    val o = Owner()
    println(o.x)
    println(o.x)
}
