package alpha

internal val state = "alpha-state"
internal var counter = 0

fun bumpAlpha(): Int {
    counter += 1
    return counter
}

fun alphaState(): String = state
