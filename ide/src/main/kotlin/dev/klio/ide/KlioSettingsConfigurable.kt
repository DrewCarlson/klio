package dev.klio.ide

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory
import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.ui.DialogPanel
import com.intellij.openapi.ui.TextFieldWithBrowseButton
import com.intellij.ui.components.JBLabel
import com.intellij.ui.dsl.builder.AlignX
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel
import com.intellij.util.ui.UIUtil
import java.io.File

/**
 * Settings | Tools | KLIO. The plugin drives the `klio` binary for everything,
 * so where that binary is, and whether it answers, is the one thing worth
 * configuring and the first thing to check when nothing works.
 */
class KlioSettingsConfigurable : BoundConfigurable("KLIO") {

    // Readable by the self-check: the label is the whole output of this page,
    // and a page that reports the wrong thing is the bug being guarded against.
    internal val detected = JBLabel()

    override fun createPanel(): DialogPanel {
        val settings = KlioSettings.getInstance()
        return panel {
            row("klio binary:") {
                cell(
                    TextFieldWithBrowseButton().apply {
                        addBrowseFolderListener(
                            null,
                            FileChooserDescriptorFactory.singleFile()
                                .withTitle("Select the klio Binary")
                                .withDescription("Leave empty to use the one on PATH"),
                        )
                    }
                )
                    .align(AlignX.FILL)
                    .bindText(settings::binaryPath)
                    .comment("Leave empty to use <code>klio</code> from PATH, or from KLIO_HOME.")
            }
            row("") {
                cell(detected).applyToComponent { foreground = UIUtil.getContextHelpForeground() }
            }
            row {
                button("Detect") { refreshDetected() }
                    .comment("Runs <code>klio --version</code> with the current setting.")
            }
            separator()
            row("Data home:") {
                label(KlioCli.dataHome().path).applyToComponent { foreground = UIUtil.getContextHelpForeground() }
            }
            row {
                button("Drop Materialised Sources") { dropMaterialised() }
                    .comment(
                        "Removes the pack sources the IDE reads under <code>.klio/ide</code>. " +
                            "The next sync writes them again."
                    )
            }
        }.also { refreshDetected() }
    }

    /**
     * Detection runs the binary, and this panel is built on the UI thread,
     * which cannot wait on a process. The work goes to a pooled thread and the
     * answer comes back to the label; asking klio inline is what made a working
     * binary look broken.
     */
    private fun refreshDetected() {
        detected.text = "Checking..."
        inBackground(work = { KlioCli.describeStatus() }, onDone = { detected.text = it })
    }

    private fun dropMaterialised() {
        val binary = KlioCli.findBinary() ?: return
        detected.text = "Dropping materialised sources..."
        inBackground(
            work = {
                try {
                    KlioCli.run(listOf("ide", "gc"), binary.parentFile ?: File(".")).trim()
                } catch (e: Exception) {
                    e.message ?: "klio ide gc failed"
                }
            },
            onDone = { detected.text = it },
        )
    }

    private fun <T> inBackground(work: () -> T, onDone: (T) -> Unit) {
        ApplicationManager.getApplication().executeOnPooledThread {
            val result = work()
            ApplicationManager.getApplication().invokeLater({ onDone(result) }, ModalityState.any())
        }
    }
}
