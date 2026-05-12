@RequiresOptIn
annotation class Experimental

@Experimental
fun risky(): Int = 1

fun caller(): Int = risky()
