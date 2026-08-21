class T {
    @Target(AnnotationTarget.PROPERTY, AnnotationTarget.CLASS)
    annotation class CustomAnnotation(val value: String)

    @CustomAnnotation("sealed")
    sealed class Result { class OK(val s: String): Result() }

    private fun List<Annotation>.getCustom(): String = "n=" + size

    fun doTest(l: List<Annotation>): String = l.getCustom()
}

fun main() {
    println(T().doTest(emptyList()))
}
