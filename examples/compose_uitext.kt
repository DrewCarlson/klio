// The real androidx.compose.ui.text surface: styled text modelling
// (AnnotatedString spans, TextStyle merge) and Paragraph construction.
// Output is deterministic with or without a Skia backend: it reports the
// style MODEL, never rasterized metrics.
import androidx.compose.ui.text.Paragraph
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.Color

fun main() {
    val ann = buildAnnotatedString {
        append("plain ")
        withStyle(SpanStyle(color = Color.Blue, fontWeight = FontWeight.Bold)) {
            append("bold-blue")
        }
        append(" then ")
        withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) {
            append("underlined")
        }
    }
    println("text=" + ann.text)
    println("spans=" + ann.spanStyles.size)
    val first = ann.spanStyles[0]
    println("span0=" + first.start + ".." + first.end + " bold=" + (first.item.fontWeight == FontWeight.Bold))

    val style = TextStyle(color = Color.Red, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    val merged = style.merge(TextStyle(fontStyle = FontStyle.Italic, textAlign = TextAlign.Center))
    println("merged size=" + merged.fontSize + " weight=" + merged.fontWeight)
    println("merged italic=" + (merged.fontStyle == FontStyle.Italic) + " align=" + merged.textAlign)

    val p = Paragraph(
        text = ann.text,
        style = TextStyle(fontSize = 14.sp),
        constraints = Constraints(maxWidth = 120),
        density = Density(1f),
        fontFamilyResolver = createFontFamilyResolver(),
    )
    println("paragraph lines>=1: " + (p.lineCount >= 1))
    println("paragraph width=" + p.width)
}
