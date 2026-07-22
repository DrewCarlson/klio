import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

fun main(args: Array<String>) {
    val out = if (args.isNotEmpty()) args[0] else "render.png"
    val ui = uiRenderer(64, 48) {
        Column(Modifier.None.background(Color.Blue).border(Color.White).padding(2)) {
            Text("iOS", Color.White, Modifier.None)
            Box(Modifier.None.size(24, 14).background(Color.Red).border(Color.Yellow).cornerRadius(2))
        }
    }
    val rc = ui.savePng(out, 4)
    ui.dispose()
    println("rendered rc=$rc to $out")
}
