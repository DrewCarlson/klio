// expect-error: T0114
class Delegate {
    suspend operator fun getValue(thisRef: Any?, prop: Any?): Int = 1
}
