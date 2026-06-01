import std/[httpclient, strutils]
import chronicles

proc slugifyProjectName*(name: string): string =
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

proc ntfySubscribeUrl*(topic: string): string =
  "https://ntfy.sh/" & topic

proc postToNtfy*(
  topic: string,
  message: string,
  title: string = "Obisan Notification",
  priority: string = "high"
) =
  if topic.len == 0:
    return

  let client = newHttpClient()
  let url = ntfySubscribeUrl(topic)

  var headers = newHttpHeaders()
  headers["Title"] = title
  headers["Priority"] = priority
  headers["Tags"] = "rotating_light"

  try:
    discard client.request(url, httpMethod = HttpPost, headers = headers, body = message)
    info "Sent ntfy.sh notification", topic = topic, title = title
  except CatchableError as e:
    error "Failed to send ntfy.sh notification", topic = topic, error = e.msg
  finally:
    client.close()
