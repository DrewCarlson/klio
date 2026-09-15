package dev.klio.ide

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project

class KlioSyncAction : AnAction() {
    override fun actionPerformed(event: AnActionEvent) {
        val project = event.project ?: return
        syncInBackground(project, refresh = true)
    }

    companion object {
        /** Skips silently when another caller already claimed the open sync. */
        fun syncOnOpen(project: Project) {
            try {
                KlioProjectImporter.syncOnOpen(project)?.let { notify(project, it) }
            } catch (e: Exception) {
                notifyError(project, e.message ?: e.toString())
            }
        }

        fun syncInBackground(project: Project, refresh: Boolean) {
            ProgressManager.getInstance().run(object : Task.Backgroundable(project, "Syncing klio project", true) {
                override fun run(indicator: ProgressIndicator) {
                    indicator.text = "Running klio ide model"
                    try {
                        val model = KlioProjectImporter.sync(project, refresh)
                        notify(project, model)
                    } catch (e: Exception) {
                        notifyError(project, e.message ?: e.toString())
                    }
                }
            })
        }

        private fun notify(project: Project, model: KlioProjectModel) {
            val group = NotificationGroupManager.getInstance().getNotificationGroup("KLIO")
            val text = buildString {
                append("${model.modules.size} modules, Kotlin ${model.kotlin}")
                if (model.problems.isNotEmpty()) {
                    append("\n")
                    append(model.problems.joinToString("\n"))
                }
            }
            val type = if (model.problems.isEmpty()) NotificationType.INFORMATION else NotificationType.WARNING
            group.createNotification("klio project synced", text, type).notify(project)
        }

        private fun notifyError(project: Project, message: String) {
            NotificationGroupManager.getInstance().getNotificationGroup("KLIO")
                .createNotification("klio sync failed", message, NotificationType.ERROR)
                .notify(project)
        }
    }
}
