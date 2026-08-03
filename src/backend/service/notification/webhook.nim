import std/[httpclient, json, os, strutils, times]
import chronicles
import ./types

# ---------------------------------------------------------------------------
# WebhookChannel
# ---------------------------------------------------------------------------

type WebhookChannel* = ref object of NotificationChannel
  url*: string
  webhookType*: string # "generic", "googlechat", "slack", "discord"

proc newWebhookChannel*(
    url: string,
    webhookType: string = "generic",
    name: string = "webhook",
    enabled: bool = true,
): WebhookChannel =
  ## Create a webhook notification channel.
  ## `webhookType` controls the payload format:
  ##   - "generic"     — raw JSON with type/project/data keys
  ##   - "googlechat"  — Google Chat card format
  ##   - "slack"       — Slack attachment format
  ##   - "discord"     — Discord embed format
  WebhookChannel(
    url: url, webhookType: webhookType, name: name, enabled: enabled and url.len > 0
  )

# ---------------------------------------------------------------------------
# Payload formatters
# ---------------------------------------------------------------------------

proc formatGoogleChatPayload(msg: NotificationMessage): JsonNode =
  let bodyHtml = msg.body.replace("\n", "<br>")
  %*{
    "cards": [
      {
        "header": {"title": msg.title},
        "sections": [{"widgets": [{"textParagraph": {"text": bodyHtml}}]}],
      }
    ]
  }

proc formatSlackPayload(msg: NotificationMessage): JsonNode =
  let color =
    case msg.priority
    of npHigh: "#ff0000"
    of npNormal: "#36a64f"
    of npLow: "#cccccc"

  var fields = newJArray()
  add(fields, %* {"title": "Details", "value": msg.body, "short": false})
  if msg.data.kind == JObject:
    for key, val in msg.data:
      add(fields, %* {"title": key, "value": $val, "short": true})

  %*{
    "attachments": [
      {
        "color": color,
        "title": msg.title,
        "fields": fields,
        "footer": "Obisan",
        "ts": epochTime().int,
      }
    ]
  }

proc formatDiscordPayload(msg: NotificationMessage): JsonNode =
  let color =
    case msg.priority
    of npHigh: 0xff0000
    of npNormal: 0x36a64f
    of npLow: 0xcccccc

  var fields = newJArray()
  add(fields, %* {"name": "Details", "value": msg.body, "inline": false})
  if msg.data.kind == JObject:
    for key, val in msg.data:
      add(fields, %* {"name": key, "value": $val, "inline": true})

  %*{
    "content": "",
    "embeds": [
      {
        "title": msg.title,
        "description": msg.body,
        "color": color,
        "fields": fields,
        "footer": {"text": "Obisan"},
        "timestamp": $(%msg.data{"checkedAt"}),
      }
    ],
  }

proc formatGenericPayload(msg: NotificationMessage): JsonNode =
  %*{
    "type": msg.eventType,
    "project": {"id": msg.projectId, "name": msg.projectName},
    "data": msg.data,
  }

# ---------------------------------------------------------------------------
# Select formatter by webhook type
# ---------------------------------------------------------------------------

proc buildWebhookPayload(channel: WebhookChannel, msg: NotificationMessage): JsonNode =
  case channel.webhookType.toLowerAscii()
  of "googlechat", "google_chat", "google":
    formatGoogleChatPayload(msg)
  of "slack":
    formatSlackPayload(msg)
  of "discord":
    formatDiscordPayload(msg)
  else:
    formatGenericPayload(msg)

# ---------------------------------------------------------------------------
# Send
# ---------------------------------------------------------------------------

proc send*(channel: WebhookChannel, msg: NotificationMessage, timeoutMs: int) =
  if channel.url.len == 0 or not channel.enabled:
    return

  let payload = buildWebhookPayload(channel, msg)

  # Retry loop
  for attempt in 0 .. 2:
    if attempt > 0:
      sleep(500)
    let client = newHttpClient(timeout = timeoutMs)
    var headers = newHttpHeaders()
    headers["Content-Type"] = "application/json"
    headers["X-Obisan-Event"] = msg.eventType
    try:
      discard client.request(
        channel.url, httpMethod = HttpPost, headers = headers, body = payload.pretty
      )
      info "Sent webhook",
        url = channel.url, eventType = msg.eventType, webhookType = channel.webhookType
      client.close()
      return
    except CatchableError as e:
      error "Failed to send webhook",
        url = channel.url, eventType = msg.eventType, error = e.msg, attempt = attempt
    finally:
      client.close()

  error "Webhook notification failed after retries", url = channel.url

# ---------------------------------------------------------------------------
# Legacy compatibility helpers
# ---------------------------------------------------------------------------

proc normalizeWebhookUrl*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    return
  if result.len > 2048:
    raise newException(ValueError, "Webhook URL too long")
  let lowered = result.toLowerAscii()
  if not (lowered.startsWith("http://") or lowered.startsWith("https://")):
    raise newException(ValueError, "Webhook URL must start with http:// or https://")

proc webhookPayload*(
    eventType, projectId, projectName: string, data: JsonNode
): JsonNode =
  %*{
    "type": eventType, "project": {"id": projectId, "name": projectName}, "data": data
  }
