/*
 * Native finalizers: the cheap form of a cleaner for a Kotlin peer of a
 * native object. The runtime calls the C function on the pointer once, when
 * the peer's close() asks or after a collection frees the peer, with no
 * Kotlin code in between.
 */
package klio.ref

/**
 * Calls the C function [finalizer], a `void (*)(void*)`, on [pointer] once
 * [owner] is garbage, unless [runNativeFinalizer] ran it first. Returns the
 * registration's handle, which only [owner] may hold.
 */
public external fun registerNativeFinalizer(owner: Any, finalizer: Long, pointer: Long): Long

/** Runs the registration's finalizer now unless it already ran; true when this call ran it. */
public external fun runNativeFinalizer(handle: Long): Boolean
