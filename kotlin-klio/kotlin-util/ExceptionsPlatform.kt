/*
 * The JVM `Throwable` surface programs use beyond the common declarations.
 * These are headers: the host serves them from the stack it captures at the
 * throw site.
 */
package kotlin

import klio.StackTraceElement

/**
 * Returns an array of stack trace elements representing the stack trace
 * pertaining to this throwable.
 */
public external val Throwable.stackTrace: Array<StackTraceElement>
