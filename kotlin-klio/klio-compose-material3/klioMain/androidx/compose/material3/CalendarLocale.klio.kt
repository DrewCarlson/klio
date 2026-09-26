// klio's CalendarLocale is the ui text Locale, as on the other non-JVM skiko
// targets: a BCP 47 tag the host's ICU formats dates for.
package androidx.compose.material3

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.text.intl.Locale

actual typealias CalendarLocale = Locale

@Composable
@ReadOnlyComposable
internal actual fun defaultLocale(): CalendarLocale = Locale.current
