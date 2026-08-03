import std/strutils

const
  DefaultEventsPageSize* = 20
  DefaultMetricsPageSize* = 50
  MaxEventsPageSize* = 100
  MaxMetricsPageSize* = 5000
  MaxEventSearchLen* = 200
  MaxDeleteBatch* = 100

proc sanitizeEventSearch*(raw: string): string =
  result = raw.strip()
  result = result.replace("%", "")
  result = result.replace("_", "")
  if result.len > MaxEventSearchLen:
    result = result[0 ..< MaxEventSearchLen]

proc parseQueryInt*(value: string, defaultValue, minValue, maxValue: int): int =
  if value.len == 0:
    return defaultValue
  try:
    let parsed = parseInt(value)
    if parsed < minValue:
      minValue
    elif parsed > maxValue:
      maxValue
    else:
      parsed
  except ValueError:
    defaultValue

proc likePattern*(search: string): string =
  "%" & search & "%"
