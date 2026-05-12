@Target(AnnotationTarget.CLASS)
annotation class OnlyOnClass

@OnlyOnClass
fun f() {}
