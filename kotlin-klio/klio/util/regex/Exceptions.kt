/*
 * The exception `Regex` raises for a pattern it cannot compile, the JVM's
 * `java.util.regex.PatternSyntaxException`: an `IllegalArgumentException`
 * whose message names the problem, its index and the pattern.
 */
package klio.util.regex

public open class PatternSyntaxException : IllegalArgumentException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}
