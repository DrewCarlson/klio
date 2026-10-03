// A value class passes through a generic delegate boxed, as kotlinc has it:
// `setValue` receives the instance (not its number) for a member, top-level,
// local and extension property, the instance is what `getValue` hands back,
// and an extension property on a value class gets the instance as thisRef.
@JvmInline
value class Role(val value: Int) {
    override fun toString(): String = "Role#" + value
}
class Cell<T>(var v: T) {
    operator fun getValue(thisRef: Any?, p: kotlin.reflect.KProperty<*>): T = v
    operator fun setValue(thisRef: Any?, p: kotlin.reflect.KProperty<*>, value: T) {
        v = value
        println(p.name + " " + (thisRef is Role) + " " + (value is Role) + " " + value)
    }
}
class Owner { var role: Role by Cell(Role(1)) }
var top: Role by Cell(Role(2))
var Role.label: String by Cell("none")
fun twice(r: Role): Int = r.value * 2
fun main() {
    val o = Owner()
    o.role = Role(6)
    println(twice(o.role))
    top = Role(7)
    println(twice(top))
    var local: Role by Cell(Role(3))
    local = Role(8)
    println(twice(local))
    Role(9).label = "nine"
    println(Role(9).label)
}
