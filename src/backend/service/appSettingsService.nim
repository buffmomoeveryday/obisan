import json
import options
import strutils

import ../database/db
import ./dbService

type AppSettings* = object
  ntfyServerUrl*: string
  ntfyUsername*: string
  ntfyPassword*: string
  ntfyToken*: string
  smtpHost*: string
  smtpPort*: int
  smtpUsername*: string
  smtpPassword*: string
  smtpFromAddr*: string
  smtpUseTls*: bool

const SettingKeys = [
  "ntfyServerUrl",
  "ntfyUsername",
  "ntfyPassword",
  "ntfyToken",
  "smtpHost",
  "smtpPort",
  "smtpUsername",
  "smtpPassword",
  "smtpFromAddr",
  "smtpUseTls"
]

proc normalizeOptionalUrl(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    return
  if result.len > 2048:
    raise newException(ValueError, "URL too long")
  let lowered = result.toLowerAscii()
  if not (lowered.startsWith("http://") or lowered.startsWith("https://")):
    raise newException(ValueError, "URL must start with http:// or https://")
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc normalizeOptionalText(raw: string, maxLen: int, label: string): string =
  result = raw.strip()
  if result.len > maxLen:
    raise newException(ValueError, label & " is too long")

proc parseBoolValue(raw: string, defaultValue: bool): bool =
  let value = raw.strip().toLowerAscii()
  if value.len == 0:
    return defaultValue
  value in ["1", "true", "yes", "on"]

proc parsePortValue(raw: string): int =
  if raw.strip().len == 0:
    return 0
  try:
    result = parseInt(raw.strip())
  except ValueError:
    raise newException(ValueError, "SMTP port must be a number")
  if result < 0 or result > 65535:
    raise newException(ValueError, "SMTP port must be between 0 and 65535")

proc getSetting*(db: DbConn, key: string): string =
  let row = db.getRow(dbSql"SELECT value FROM app_settings WHERE key = ?", key)
  if row.isSome:
    dbText(row.get[0])
  else:
    ""

proc setSetting*(db: DbConn, key, value: string) =
  db.exec(
    dbSql"""INSERT INTO app_settings (key, value)
          VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value""",
    key,
    value
  )

proc loadAppSettings*(db: DbConn): AppSettings =
  result.ntfyServerUrl = getSetting(db, "ntfyServerUrl")
  if result.ntfyServerUrl.len == 0:
    result.ntfyServerUrl = "https://ntfy.sh"
  result.ntfyUsername = getSetting(db, "ntfyUsername")
  result.ntfyPassword = getSetting(db, "ntfyPassword")
  result.ntfyToken = getSetting(db, "ntfyToken")
  result.smtpHost = getSetting(db, "smtpHost")
  result.smtpPort = parsePortValue(getSetting(db, "smtpPort"))
  result.smtpUsername = getSetting(db, "smtpUsername")
  result.smtpPassword = getSetting(db, "smtpPassword")
  result.smtpFromAddr = getSetting(db, "smtpFromAddr")
  result.smtpUseTls = parseBoolValue(getSetting(db, "smtpUseTls"), true)

proc loadAppSettings*(): AppSettings =
  withDb dbPool:
    result = loadAppSettings(db)

proc settingsToJson*(settings: AppSettings): JsonNode =
  %* {
    "ntfyServerUrl": settings.ntfyServerUrl,
    "ntfyUsername": settings.ntfyUsername,
    "ntfyTokenConfigured": settings.ntfyToken.len > 0,
    "ntfyPasswordConfigured": settings.ntfyPassword.len > 0,
    "smtpHost": settings.smtpHost,
    "smtpPort": settings.smtpPort,
    "smtpUsername": settings.smtpUsername,
    "smtpPasswordConfigured": settings.smtpPassword.len > 0,
    "smtpFromAddr": settings.smtpFromAddr,
    "smtpUseTls": settings.smtpUseTls
  }

proc updateAppSettings*(db: DbConn, body: JsonNode): AppSettings =
  var current = loadAppSettings(db)

  if "ntfyServerUrl" in body:
    current.ntfyServerUrl = normalizeOptionalUrl(body["ntfyServerUrl"].getStr())
    if current.ntfyServerUrl.len == 0:
      current.ntfyServerUrl = "https://ntfy.sh"
  if "ntfyUsername" in body:
    current.ntfyUsername = normalizeOptionalText(body["ntfyUsername"].getStr(), 255, "ntfy username")
  if "ntfyPassword" in body:
    let value = body["ntfyPassword"].getStr()
    if value.len > 0 or current.ntfyPassword.len == 0:
      current.ntfyPassword = normalizeOptionalText(value, 2048, "ntfy password")
  if "clearNtfyPassword" in body and body["clearNtfyPassword"].getBool():
    current.ntfyPassword = ""
  if "ntfyToken" in body:
    let value = body["ntfyToken"].getStr()
    if value.len > 0 or current.ntfyToken.len == 0:
      current.ntfyToken = normalizeOptionalText(value, 4096, "ntfy token")
  if "clearNtfyToken" in body and body["clearNtfyToken"].getBool():
    current.ntfyToken = ""

  if "smtpHost" in body:
    current.smtpHost = normalizeOptionalText(body["smtpHost"].getStr(), 255, "SMTP host")
  if "smtpPort" in body:
    current.smtpPort = parsePortValue($body["smtpPort"].getInt())
  if "smtpUsername" in body:
    current.smtpUsername = normalizeOptionalText(body["smtpUsername"].getStr(), 255, "SMTP username")
  if "smtpPassword" in body:
    let value = body["smtpPassword"].getStr()
    if value.len > 0 or current.smtpPassword.len == 0:
      current.smtpPassword = normalizeOptionalText(value, 2048, "SMTP password")
  if "clearSmtpPassword" in body and body["clearSmtpPassword"].getBool():
    current.smtpPassword = ""
  if "smtpFromAddr" in body:
    current.smtpFromAddr = normalizeOptionalText(body["smtpFromAddr"].getStr(), 320, "SMTP sender")
  if "smtpUseTls" in body:
    current.smtpUseTls = body["smtpUseTls"].getBool()

  for key in SettingKeys:
    case key
    of "ntfyServerUrl": setSetting(db, key, current.ntfyServerUrl)
    of "ntfyUsername": setSetting(db, key, current.ntfyUsername)
    of "ntfyPassword": setSetting(db, key, current.ntfyPassword)
    of "ntfyToken": setSetting(db, key, current.ntfyToken)
    of "smtpHost": setSetting(db, key, current.smtpHost)
    of "smtpPort": setSetting(db, key, $current.smtpPort)
    of "smtpUsername": setSetting(db, key, current.smtpUsername)
    of "smtpPassword": setSetting(db, key, current.smtpPassword)
    of "smtpFromAddr": setSetting(db, key, current.smtpFromAddr)
    of "smtpUseTls": setSetting(db, key, $current.smtpUseTls)
    else: discard

  current
