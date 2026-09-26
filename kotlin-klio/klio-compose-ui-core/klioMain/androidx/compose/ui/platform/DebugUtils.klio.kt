package androidx.compose.ui.platform

import androidx.compose.ui.internal.identityHashCode

/**
 * `Name@1a2b3c4`: [name], else the class's simple name, then the object's
 * identity hash as seven hex digits, as the desktop actual formats it (which
 * reads the name from the Java class).
 */
internal actual fun simpleIdentityToString(obj: Any, name: String?): String {
    val className = name ?: obj::class.simpleName ?: "<anonymous>"
    return className + "@" + identityHashCode(obj).toUInt().toString(16).padStart(7, '0')
}
