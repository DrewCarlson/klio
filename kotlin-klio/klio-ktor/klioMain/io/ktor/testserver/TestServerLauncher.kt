/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The `test-server` feature's entry point, under the pack's `io.ktor`
// namespace: ktor's own test server (package `test.server`, build
// infrastructure upstream) started the way upstream's Gradle service starts
// it before the client test runs.

package io.ktor.testserver

import kotlinx.coroutines.*

/**
 * Starts ktor's test servers (see `test.server.startServer`) and serves until
 * the process ends. Prints `test server started` once every server listens.
 */
public fun runTestServer(verbose: Boolean = false) {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    test.server.startServer(scope, verbose)
    println("test server started")
    runBlocking { scope.coroutineContext.job.join() }
}
