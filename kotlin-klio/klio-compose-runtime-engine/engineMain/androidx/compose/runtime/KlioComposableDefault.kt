package androidx.compose.runtime

// The absent-argument sentinel for the klio compose lowering pass. A defaulted
// @Composable parameter's declared default is replaced with a call to
// klioComposableDefaultMarker(); the function body then evaluates the real
// default expression only when the marker arrives, with the threaded $composer
// in scope. Identity (===) against the singleton is the presence test, the
// same role the upstream plugin's $default bitmask plays.
object KlioComposableDefaultMarker

fun klioComposableDefaultMarker(): Any = KlioComposableDefaultMarker
