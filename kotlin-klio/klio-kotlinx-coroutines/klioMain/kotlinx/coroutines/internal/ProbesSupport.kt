/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package kotlinx.coroutines.internal

import kotlin.coroutines.Continuation

/**
 * klio actuals for the coroutine debug probes: identity/no-op, like the
 * js target. Without an actual the unsettled header no-ops to Unit and
 * `startCoroutineUndispatched`'s completion is swallowed.
 */
internal actual inline fun <T> probeCoroutineCreated(completion: Continuation<T>): Continuation<T> = completion

internal actual inline fun <T> probeCoroutineResumed(completion: Continuation<T>) {}
