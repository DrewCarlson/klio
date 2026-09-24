/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The skiko surface ui's SystemTheme.kt (skikoMain) reads. skiko asks the
// operating system for its appearance and answers UNKNOWN where it cannot
// tell; klio's host reports no appearance, so the theme is UNKNOWN.
package org.jetbrains.skiko

enum class SystemTheme {
    LIGHT,
    DARK,
    UNKNOWN,
}

val currentSystemTheme: SystemTheme
    get() = SystemTheme.UNKNOWN
