// klio shim for `Serializable` — the upstream commonMain `EmptyList`,
// `EmptyMap`, `EmptySet`, `KotlinVersion`, etc. declare this as a
// supertype but the actual interface lives in `java.io` on JVM.
// klio is platform-agnostic; ship a marker in `kotlin.io` so an
// unqualified reference resolves via Kotlin's implicit imports.

package kotlin

public interface Serializable
