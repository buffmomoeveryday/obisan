import strutils
import chronicles
import ./types
import ./ntfy
import ./webhook
import ./email
import ./pushover
import ../appSettingsService
import ../projectService

export NotificationChannel
export NotificationMessage
export NotificationPriority
export NtfyChannel, newNtfyChannel
export WebhookChannel, newWebhookChannel
export EmailChannel, newEmailChannel
export PushoverChannel, newPushoverChannel

# ---------------------------------------------------------------------------
# NotificationService — orchestrator that dispatches to all channels
# ---------------------------------------------------------------------------

type NotificationService* = ref object
  channels*: seq[NotificationChannel]
  timeoutMs*: int

const DefaultNotificationTimeoutMs* = 5000

proc newNotificationService*(
    timeoutMs: int = DefaultNotificationTimeoutMs
): NotificationService =
  ## Create an empty notification service. Add channels via `add()`.
  NotificationService(channels: @[], timeoutMs: timeoutMs)

proc add*(service: NotificationService, channel: NotificationChannel) =
  ## Register a notification channel.
  service.channels.add channel

proc notify*(service: NotificationService, msg: NotificationMessage) =
  ## Dispatch a notification to all enabled channels.
  var sentCount = 0
  for channel in service.channels:
    if not channel.enabled:
      continue
    try:
      if channel of NtfyChannel:
        NtfyChannel(channel).send(msg, service.timeoutMs)
      elif channel of WebhookChannel:
        WebhookChannel(channel).send(msg, service.timeoutMs)
      elif channel of EmailChannel:
        EmailChannel(channel).send(msg, service.timeoutMs)
      elif channel of PushoverChannel:
        PushoverChannel(channel).send(msg, service.timeoutMs)
      else:
        warn "Unknown notification channel type", channelName = channel.name
        continue
      inc sentCount
    except CatchableError as e:
      error "Notification dispatch failed", channel = channel.name, error = e.msg

  if sentCount > 0:
    info "Notifications dispatched", sent = sentCount, total = service.channels.len
  else:
    warn "No notification channels were available to send", total = service.channels.len

# ---------------------------------------------------------------------------
# Convenience builder — construct a service from a project's stored config
# ---------------------------------------------------------------------------

proc buildProjectNotificationService*(
    ntfyTopic, webhookUrl: string,
    notificationConfigs: string = "",
    webhookType: string = "generic",
    projectName: string = "",
): NotificationService =
  ## Build a NotificationService from the project's `ntfyTopic` and
  ## `webhookUrl` columns — backward compatible with the existing schema.
  result = newNotificationService()
  let settings = loadAppSettings()
  let projectSettings = parseProjectNotificationSettings(notificationConfigs)
  if ntfyTopic.len > 0:
    result.add newNtfyChannel(
      ntfyTopic,
      name = "ntfy - " & projectName,
      server = settings.ntfyServerUrl,
      username = settings.ntfyUsername,
      password = settings.ntfyPassword,
      token = settings.ntfyToken
    )
  if webhookUrl.len > 0:
    result.add newWebhookChannel(
      webhookUrl, webhookType, name = "webhook - " & projectName
    )
  if projectSettings.emailEnabled and settings.smtpHost.len > 0 and
      settings.smtpFromAddr.len > 0 and projectSettings.emailToAddrs.len > 0:
    result.add newEmailChannel(
      settings.smtpHost,
      settings.smtpPort,
      settings.smtpUsername,
      settings.smtpPassword,
      settings.smtpFromAddr,
      projectSettings.emailToAddrs.split(','),
      name = "smtp - " & projectName,
      useTls = settings.smtpUseTls
    )
