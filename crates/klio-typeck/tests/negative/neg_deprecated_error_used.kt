@Deprecated("use bar()", level = DeprecationLevel.ERROR)
fun foo(): Int = 1

fun caller(): Int = foo()
