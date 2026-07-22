package themed

fun render(tone: Int = 1, content: () -> Unit) {
    println("short:$tone")
    content()
}

fun render(tone: Int = 1, weight: Int = 2, content: () -> Unit) {
    println("long:$tone:$weight")
    content()
}
