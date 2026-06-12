package beta

internal val state = "beta-state"
internal var counter = 100

fun bumpBeta(): Int {
    counter += 1
    return counter
}

fun betaState(): String = state
