import std/[base64, httpclient, os, strutils]
import chronicles
import ./types

const
  MaxRetries* = 2
  RetryPauseMs* = 500

proc withRetry(action: proc(): bool {.closure.}, maxRetries: int = MaxRetries): bool =
  for attempt in 0 .. maxRetries:
    if attempt > 0:
      sleep(RetryPauseMs)
    if action():
      return true
  false

proc newTimedClient(timeoutMs: int): HttpClient =
  newHttpClient(timeout = timeoutMs)

# ---------------------------------------------------------------------------
# NtfyChannel
# ---------------------------------------------------------------------------

type
  NtfyChannel* = ref object of NotificationChannel
    topic*: string
    server*: string  # e.g. "https://ntfy.sh"
    username*: string
    password*: string
    token*: string

proc newNtfyChannel*(topic: string, name: string = "ntfy.sh",
                     server: string = "https://ntfy.sh",
                     username: string = "",
                     password: string = "",
                     token: string = "",
                     enabled: bool = true): NtfyChannel =
  ## Create an ntfy.sh notification channel.
  NtfyChannel(
    topic: topic,
    server: server,
    username: username,
    password: password,
    token: token,
    name: name,
    enabled: enabled and topic.len > 0
  )

proc send*(channel: NtfyChannel, msg: NotificationMessage, timeoutMs: int) =
  if channel.topic.len == 0 or not channel.enabled:
    return

  let server = if channel.server.len > 0: channel.server else: "https://ntfy.sh"
  let url = server & "/" & channel.topic

  let priorityStr =
    case msg.priority
    of npLow:    "low"
    of npNormal: "default"
    of npHigh:   "high"

  let sendAction = proc(): bool =
    let client = newTimedClient(timeoutMs)
    var headers = newHttpHeaders()
    headers["Title"] = msg.title
    headers["Priority"] = priorityStr
    headers["Tags"] = "rotating_light"
    if channel.token.len > 0:
      headers["Authorization"] = "Bearer " & channel.token
    elif channel.username.len > 0 or channel.password.len > 0:
      headers["Authorization"] = "Basic " & encode(channel.username & ":" & channel.password)
    try:
      discard client.request(url, httpMethod = HttpPost, headers = headers, body = msg.body)
      info "Sent ntfy.sh notification", topic = channel.topic, title = msg.title
      result = true
    except CatchableError as e:
      error "Failed to send ntfy.sh notification", topic = channel.topic, error = e.msg
    finally:
      client.close()

  if not withRetry(sendAction):
    error "Ntfy notification failed after retries", topic = channel.topic

# ---------------------------------------------------------------------------
# Legacy compatibility — slug generation from existing project config
# ---------------------------------------------------------------------------

proc slugifyProjectName*(name: string): string =
  ## Convert a project name into an ntfy.sh-compatible slug.
  var slug = ""
  for c in name.toLowerAscii():
    if c.isAlphaNumeric:
      slug.add c
    elif c in {' ', '-', '_', '.'}:
      if slug.len > 0 and slug[^1] != '-':
        slug.add '-'
  while slug.len > 0 and slug[0] == '-':
    slug = slug[1 .. ^1]
  while slug.len > 0 and slug[^1] == '-':
    slug.setLen(slug.len - 1)
  if slug.len == 0:
    return "project"
  if slug.len > 40:
    slug = slug[0 ..< 40]
    while slug.len > 0 and slug[^1] == '-':
      slug.setLen(slug.len - 1)
  slug

proc generateNtfyTopic*(projectId: int, projectName: string): string =
  "obisan-" & slugifyProjectName(projectName) & "-" & $projectId

proc ntfySubscribeUrl*(topic: string, server: string = "https://ntfy.sh"): string =
  let baseUrl =
    if server.len > 0:
      server
    else:
      "https://ntfy.sh"
  baseUrl & "/" & topic
