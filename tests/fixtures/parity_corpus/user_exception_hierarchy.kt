open class MyErr : RuntimeException("boom")
class SubErr : MyErr()
class TreeErr : Throwable()

fun main() {
    try { throw MyErr() } catch (e: RuntimeException) { println("caught MyErr via RuntimeException") }
    try { throw MyErr() } catch (e: Exception) { println("caught MyErr via Exception") }
    try { throw MyErr() } catch (e: Throwable) { println("caught MyErr via Throwable") }
    try { throw SubErr() } catch (e: MyErr) { println("caught SubErr via MyErr") }
    try { throw TreeErr() } catch (e: Throwable) { println("caught TreeErr via Throwable") }

    try {
        try { throw SubErr() } catch (e: TreeErr) { println("wrong: TreeErr") }
    } catch (e: MyErr) {
        println("propagated to MyErr")
    }
}
