import std/[httpclient, json, os]
import chronicles
import ./types

# ---------------------------------------------------------------------------
# PushoverChannel
# ---------------------------------------------------------------------------

type PushoverChannel* = ref object of NotificationChannel
  userKey*: string
  apiToken*: string

proc newPushoverChannel*(
    userKey, apiToken: string, name: string = "pushover", enabled: bool = true
): PushoverChannel =
  ## Create a Pushover push notification channel.
  PushoverChannel(
    userKey: userKey,
    apiToken: apiToken,
    name: name,
    enabled: enabled and userKey.len > 0 and apiToken.len > 0,
  )

proc send*(channel: PushoverChannel, msg: NotificationMessage, timeoutMs: int) =
  ## Sends a push notification via Pushover API (https://pushover.net).
  if channel.userKey.len == 0 or channel.apiToken.len == 0 or not channel.enabled:
    return

  let priorityInt =
    case msg.priority
    of npLow: -1
    of npNormal: 0
    of npHigh: 1

  for attempt in 0 .. 2:
    if attempt > 0:
      sleep(500)
    let client = newHttpClient(timeout = timeoutMs)
    var headers = newHttpHeaders()
    headers["Content-Type"] = "application/json"

    let payload =
      %*{
        "token": channel.apiToken,
        "user": channel.userKey,
        "message":
          if msg.body.len > 1024:
            msg.body[0 ..< 1024]
          else:
            msg.body,
        "title":
          if msg.title.len > 250:
            msg.title[0 ..< 250]
          else:
            msg.title,
        "priority": priorityInt,
        "sound": "pushover",
      }

    try:
      discard client.request(
        "https://api.pushover.net/1/messages.json",
        httpMethod = HttpPost,
        headers = headers,
        body = payload.pretty,
      )
      info "Sent pushover notification", user = channel.userKey[0 .. 3] & "..."
      client.close()
      return
    except CatchableError as e:
      error "Failed to send pushover notification", error = e.msg, attempt = attempt
    finally:
      client.close()

  error "Pushover notification failed after retries"
