// Renaming imports of functions: `import a.b.f as g` binds `g` for bare
// calls (including multi-overload intrinsic symbols like kotlin.math.max)
// and for explicit-receiver extension calls.

import kotlin.math.max as biggest
import kotlin.text.uppercase as shout

fun main() {
    println(biggest(3, 7))
    println("hi".shout())
}
