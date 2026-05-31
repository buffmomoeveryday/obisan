import std/httpclient, std/json, chronicles

proc sendNtfyNotification*(topic: string, message: string, title: string = "Obisan Notification", priority: string = "default") =
  let client = newAsyncHttpClient()
  let url = "https://ntfy.sh/" & topic

  var headers = newHttpHeaders()
  headers["Title"] = title
  headers["Priority"] = priority
  headers["Content-Type"] = "application/json"

  let payload = %* {"message": message, "timestamp": epochTime()}

  try:
    discard waitFor client.post(url, body = $payload, headers = headers)
    info "Sent ntfy.sh notification", topic = topic, message = message
  except CatchableError as e:
    error "Failed to send ntfy.sh notification", error = e.msg


proc notifyError*(projectId: string, errorType: string, message: string) =
  let topic = "obisan-" & projectId
  sendNtfyNotification(topic, message, "Obisan Error Alert", "high")
