/*
 * The element type of the `Throwable.stackTrace` array. The host renders
 * each captured frame as its text, `function(File.kt:line)`, and the members
 * read the parts back.
 */
package klio

/**
 * One frame of a throwable's captured stack.
 */
public external class StackTraceElement {
    /** The qualifier of the frame's function. */
    public val className: String

    /** The frame's function name. */
    public val methodName: String

    /** The name of the frame's source file, or null when it has none. */
    public val fileName: String?

    /** The frame's line, or a negative number when it has none. */
    public val lineNumber: Int
}
