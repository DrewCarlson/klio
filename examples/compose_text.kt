// Compose ui-text model — AnnotatedString and its Builder, SpanStyle,
// FontWeight, and TextAlign, running through the real vendored
// androidx.compose.ui.text pack (over ui-graphics / ui-unit / runtime /
// runtime-saveable). buildAnnotatedString pushes a styled span and pops it.

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.graphics.Color

fun main() {
    val a = AnnotatedString("hello")
    println("annotated=${a.text} len=${a.length}")

    val b = buildAnnotatedString {
        append("bold")
        pushStyle(SpanStyle(color = Color.Red, fontWeight = FontWeight.Bold))
        append("!")
        pop()
    }
    println("built=${b.text} spans=${b.spanStyles.size}")
    println("weight=${FontWeight.Bold.weight} align=${TextAlign.Center}")
}
