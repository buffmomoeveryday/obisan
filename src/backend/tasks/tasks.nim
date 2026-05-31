import quee
import chronicles
import times
import ../database/db


task processSentryEvent(eventId: string, projectId: string, errorType: string, message: string):
  queue "notifications"
  info "Processing Sentry event", eventId = eventId, projectId = projectId, errorType = errorType

task sendNtfyNotification(projectId: string, message: string, title: string = "Obisan Alert"):
  queue "notifications"
  info "Sending ntfy notification", projectId = projectId, message = message

task cleanupOldEvents(daysToKeep: int = 30):
  info "Cleaning up old events older than", days = daysToKeep

task backupProject(projectId: string):
  queue "urgent"
  info "Creating backup for project", projectId = projectId

task sendWelcomeEmail(email: string, projectName: string):
  queue "notifications"
  info "Sending welcome email", email = email, project = projectName
