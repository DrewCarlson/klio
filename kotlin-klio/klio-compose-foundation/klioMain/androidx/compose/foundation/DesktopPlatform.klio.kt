/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation

/**
 * klio adaptation of upstream's desktop `DesktopPlatform`.
 *
 * Upstream reads `System.getProperty("os.name")`, which klio has no JVM to serve —
 * so the enum is re-authored over a host intrinsic that reports the OS klio was
 * actually built for. This is not cosmetic: the desktop text-field key mapping is
 * genuinely per-platform (macOS binds the editing shortcuts to Meta, Linux and
 * Windows to Ctrl), so defaulting to one of them would give the wrong bindings on a
 * real host.
 */
internal fun __composeui_hostOs(): String = "unknown"

internal enum class DesktopPlatform {
    Linux,
    Windows,
    MacOS,
    Unknown;

    companion object {
        private var overriddenCurrent: DesktopPlatform? = null

        private val detected: DesktopPlatform by lazy {
            when (__composeui_hostOs()) {
                "linux" -> Linux
                "windows" -> Windows
                "macos" -> MacOS
                else -> Unknown
            }
        }

        /** The OS the program is running on. */
        val Current: DesktopPlatform
            get() = overriddenCurrent ?: detected

        /** Override [Current] for the duration of [body] (tests). */
        fun <T> withOverriddenCurrent(newCurrent: DesktopPlatform, body: () -> T): T {
            try {
                overriddenCurrent = newCurrent
                return body()
            } finally {
                overriddenCurrent = null
            }
        }
    }
}
