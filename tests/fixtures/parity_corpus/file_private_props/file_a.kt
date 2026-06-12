// Two files each declare a file-private top-level LOGGER (one delegated);
// each file's references must read its own (the ktor plugins shape).
private val LOGGER = "logger-a"

fun useA(): String = LOGGER
