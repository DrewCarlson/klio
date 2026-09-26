package androidx.compose.ui.platform

import org.jetbrains.skiko.OS
import org.jetbrains.skiko.hostOs

/** The operating system the program runs on, as the desktop's reads it from os.name. */
internal enum class DesktopPlatform {
    Linux,
    Windows,
    MacOS,
    Unknown;

    companion object {
        /** Identify the operating system on which the application is currently running. */
        val Current: DesktopPlatform by lazy {
            when (hostOs) {
                OS.Linux -> Linux
                OS.Windows -> Windows
                OS.MacOS -> MacOS
                else -> Unknown
            }
        }
    }
}
