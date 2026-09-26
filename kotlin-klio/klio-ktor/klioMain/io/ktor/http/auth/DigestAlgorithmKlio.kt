/*
 * Copyright 2014-2026 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copy of ktor-http's JVM DigestAlgorithm.jvm.kt: the digester is
// klio.security.MessageDigest, the JVM MessageDigest surface over the host
// digests.

package io.ktor.http.auth

import klio.security.MessageDigest

/**
 * Creates a [MessageDigest] instance for this algorithm.
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.http.auth.toDigester)
 *
 * @return A new MessageDigest configured for this algorithm's hash function
 * @throws [klio.security.NoSuchAlgorithmException] If the algorithm is not supported
 */
public fun DigestAlgorithm.toDigester(): MessageDigest =
    MessageDigest.getInstance(hashName)
