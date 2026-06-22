/*
 * KLIO actuals for the common `Throwable` stack-trace helpers. KLIO has no
 * host stack-trace machinery, so these render the throwable itself.
 */
package kotlin

public actual fun Throwable.printStackTrace() {
    println(this)
}

public actual fun Throwable.stackTraceToString(): String = this.toString()
