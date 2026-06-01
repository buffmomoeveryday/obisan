import std/[httpclient, json, strutils]
import chronicles

const WebhookTimeoutMs* = 5000

proc normalizeWebhookUrl*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    return
  if result.len > 2048:
    raise newException(ValueError, "Webhook URL too long")
  let lowered = result.toLowerAscii()
  if not (lowered.startsWith("http://") or lowered.startsWith("https://")):
    raise newException(ValueError, "Webhook URL must start with http:// or https://")

proc postToWebhook*(url, eventType: string, payload: JsonNode) =
  if url.len == 0:
    return

  let client = newHttpClient(timeout = WebhookTimeoutMs)
  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-Obisan-Event"] = eventType

  try:
    discard client.request(url, httpMethod = HttpPost, headers = headers, body = payload.pretty)
    info "Sent webhook", url = url, eventType = eventType
  except CatchableError as e:
    error "Failed to send webhook", url = url, eventType = eventType, error = e.msg
  finally:
    client.close()

proc webhookPayload*(eventType, projectId, projectName: string, data: JsonNode): JsonNode =
  %* {
    "type": eventType,
    "project": {
      "id": projectId,
      "name": projectName
    },
    "data": data
  }
