import std/[strutils, sequtils]
import chronicles
import smtp

import ./types

# ---------------------------------------------------------------------------
# EmailChannel
# ---------------------------------------------------------------------------
type EmailChannel* = ref object of NotificationChannel
  smtpHost*: string
  smtpPort*: int
  username*: string
  password*: string
  fromAddr*: string
  toAddrs*: seq[string]
  useTls*: bool

proc newEmailChannel*(
    smtpHost: string,
    smtpPort: int,
    username, password, fromAddr: string,
    toAddrs: seq[string],
    name: string = "email",
    useTls: bool = true,
    enabled: bool = true,
  ): EmailChannel =
  ## Create an SMTP email notification channel.
  let effectiveEnabled = enabled and toAddrs.len > 0 and smtpHost.len > 0
  result = EmailChannel(
    smtpHost: smtpHost,
    smtpPort: smtpPort,
    username: username,
    password: password,
    fromAddr: fromAddr,
    toAddrs: toAddrs,
    name: name,
    useTls: useTls,
    enabled: effectiveEnabled,
  )
  debug "Email channel created",
    name = name, host = smtpHost, port = smtpPort, useTls = useTls,
    fromAddr = fromAddr, toCount = toAddrs.len, enabled = effectiveEnabled

proc sendEmail*(
    smtpHost: string,
    smtpPort: int,
    username, password, fromAddr: string,
    toAddrs: seq[string],
    subject, body: string,
    useTls: bool = true,
    timeoutMs: int = 5000,
) =
  ## Send an email via SMTP using the stdlib smtp package.
  ##
  ## TLS behaviour:
  ## - Port 465 + useTls → SSL handshake immediately.
  ## - Other ports + useTls → STARTTLS after connect (port 587 standard).
  ## - useTls = false → plaintext SMTP, no authentication.
  ##
  ## The `timeoutMs` parameter is accepted for backwards compatibility
  ## but is not directly used by the smtp package.
  let recipients = toAddrs.filterIt(it.strip().len > 0)
  let sender = fromAddr.strip()
  if smtpHost.strip().len == 0 or sender.len == 0 or recipients.len == 0:
    warn "Skipping email send — missing configuration",
      hasHost = smtpHost.len > 0, hasSender = sender.len > 0,
      recipientCount = recipients.len
    return

  let host = smtpHost.strip()
  let portValue =
    if smtpPort > 0:
      smtpPort.Port
    elif useTls:
      587.Port
    else:
      25.Port
  let useSsl = useTls and portValue.int == 465

  debug "Connecting to SMTP server",
    host = host, port = portValue.int, useSsl = useSsl,
    useStartTls = useTls and not useSsl,
    willAuth = useTls and username.strip().len > 0,
    sender = sender, recipients = recipients

  var smtpConn = newSmtp(useSsl = useSsl)
  try:
    smtpConn.connect(host, portValue)

    if useTls and not useSsl:
      debug "Starting STARTTLS", host = host
      smtpConn.startTls()

    if useTls and username.strip().len > 0:
      debug "Authenticating to SMTP", host = host, username = username.strip()
      smtpConn.auth(username.strip(), password)

    debug "Sending email via SMTP",
      host = host, sender = sender, toCount = recipients.len, subject = subject,
      bodyBytes = body.len
    let messageText =
      "From: " & sender & "\r\n" &
      "To: " & recipients.join(", ") & "\r\n" &
      "Subject: " & subject & "\r\n" &
      "Content-Type: text/plain; charset=UTF-8\r\n" &
      "\r\n" &
      body
    smtpConn.sendMail(sender, recipients, messageText)
    debug "Email sent successfully via SMTP",
      host = host, sender = sender, recipientCount = recipients.len
  finally:
    try:
      smtpConn.close()
    except CatchableError as e:
      error "Failed to close SMTP connection cleanly",
        host = host, error = e.msg

proc send*(channel: EmailChannel, msg: NotificationMessage, timeoutMs: int) =
  if channel.toAddrs.len == 0 or channel.smtpHost.len == 0 or not channel.enabled:
    debug "Skipping email channel — disabled or misconfigured",
      name = channel.name, enabled = channel.enabled,
      hasHost = channel.smtpHost.len > 0,
      recipientCount = channel.toAddrs.len
    return

  debug "Dispatching email notification",
    host = channel.smtpHost, port = channel.smtpPort,
    fromAddr = channel.fromAddr, toCount = channel.toAddrs.len,
    subject = msg.title

  let emailBody =
    msg.title & "\n" & repeat("=", msg.title.len) & "\n\n" & msg.body & "\n\n" &
    "Event: " & msg.eventType & "\n" & "Project: " & msg.projectName & " (" &
    msg.projectId & ")\n"

  sendEmail(
    channel.smtpHost, channel.smtpPort, channel.username, channel.password,
    channel.fromAddr, channel.toAddrs, msg.title, emailBody, channel.useTls, timeoutMs,
  )

  info "Email notification dispatched to SMTP",
    host = channel.smtpHost,
    port = channel.smtpPort,
    to = channel.toAddrs.join(", "),
    subject = msg.title,
    bodyBytes = emailBody.len
