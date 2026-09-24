/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The atomics of foundation's Expect.kt. The desktop actuals are typealiases of
// java.util.concurrent.atomic's; klio's are backed by kotlinx.atomicfu, whose
// operations are atomic across klio's worker threads.
package androidx.compose.foundation

import kotlinx.atomicfu.atomic

internal actual class AtomicReference<V> actual constructor(value: V) {
    private val ref = atomic(value)

    actual fun get(): V = ref.value

    actual fun set(value: V) {
        ref.value = value
    }

    actual fun getAndSet(value: V): V = ref.getAndSet(value)

    actual fun compareAndSet(expect: V, newValue: V): Boolean = ref.compareAndSet(expect, newValue)
}

internal actual class AtomicLong actual constructor(value: Long) {
    private val ref = atomic(value)

    actual fun get(): Long = ref.value

    actual fun set(value: Long) {
        ref.value = value
    }

    actual fun getAndIncrement(): Long = ref.getAndIncrement()
}
