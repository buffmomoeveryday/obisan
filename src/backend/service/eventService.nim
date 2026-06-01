import json
import options
import strutils
import norm/sqlite
import lowdb/sqlite

import ./dbService
import ./queryService

proc countProjectEvents*(db: DbConn, projectDbId: int, search: string): int =
  let row =
    if search.len == 0:
      db.getRow(
        sql"SELECT COUNT(*) FROM SentryEvent WHERE project = ? AND platform != 'log'",
        projectDbId
      )
    else:
      let pattern = likePattern(search)
      db.getRow(
        sql"""SELECT COUNT(*) FROM SentryEvent
              WHERE project = ?
              AND platform != 'log'
              AND (
                errorType LIKE ?
                OR message LIKE ?
                OR eventId LIKE ?
                OR level LIKE ?
                OR platform LIKE ?
                OR stacktrace LIKE ?
              )""",
        projectDbId,
        pattern,
        pattern,
        pattern,
        pattern,
        pattern,
        pattern
      )
  if row.isNone:
    0
  else:
    row.get[0].i.int

proc countProjectLogs*(db: DbConn, projectDbId: int, search: string): int =
  let row =
    if search.len == 0:
      db.getRow(
        sql"SELECT COUNT(*) FROM SentryEvent WHERE project = ? AND platform = 'log'",
        projectDbId
      )
    else:
      let pattern = likePattern(search)
      db.getRow(
        sql"""SELECT COUNT(*) FROM SentryEvent
              WHERE project = ?
              AND platform = 'log'
              AND (
                errorType LIKE ?
                OR message LIKE ?
                OR eventId LIKE ?
                OR level LIKE ?
                OR stacktrace LIKE ?
              )""",
        projectDbId,
        pattern,
        pattern,
        pattern,
        pattern,
        pattern
      )
  if row.isNone:
    0
  else:
    row.get[0].i.int

proc eventSummaryJson*(row: seq[DbValue]): JsonNode =
  %* {
    "eventId": dbText(row[0]),
    "errorType": dbText(row[1]),
    "message": dbText(row[2]),
    "level": dbText(row[3]),
    "platform": dbText(row[4]),
    "receivedAt": formatUnixTime(row[5].i.int64)
  }

proc eventDetailJson*(row: seq[DbValue]): JsonNode =
  %* {
    "eventId": dbText(row[0]),
    "errorType": dbText(row[1]),
    "message": dbText(row[2]),
    "level": dbText(row[3]),
    "platform": dbText(row[4]),
    "receivedAt": formatUnixTime(row[5].i.int64),
    "stacktrace": dbText(row[6])
  }

proc parseEventIds*(body: string): seq[string] =
  if body.len == 0:
    return @[]
  let data = parseJson(body)
  if "eventIds" notin data or data["eventIds"].kind != JArray:
    return @[]
  for item in data["eventIds"]:
    if item.kind == JString:
      let eventId = item.getStr().strip()
      if eventId.len > 0:
        result.add eventId
  if result.len > MaxDeleteBatch:
    raise newException(ValueError, "Too many events selected")

proc deleteProjectEventRows*(db: DbConn, projectDbId: int, eventIds: seq[string]): int =
  for eventId in eventIds:
    result += int db.execAffectedRows(
      sql"DELETE FROM SentryEvent WHERE project = ? AND eventId = ?",
      projectDbId,
      eventId
    )

proc deleteProjectEventRow*(db: DbConn, projectDbId: int, eventId: string): int64 =
  db.execAffectedRows(
    sql"DELETE FROM SentryEvent WHERE project = ? AND eventId = ?",
    projectDbId,
    eventId
  )

const eventSummarySql* = sql"""SELECT eventId, errorType, message, level, platform, receivedAt
                               FROM SentryEvent
                               WHERE project = ? AND platform != 'log'
                               ORDER BY receivedAt DESC
                               LIMIT ? OFFSET ?"""

const eventSummarySearchSql* = sql"""SELECT eventId, errorType, message, level, platform, receivedAt
                                     FROM SentryEvent
                                     WHERE project = ?
                                     AND platform != 'log'
                                     AND (
                                       errorType LIKE ?
                                       OR message LIKE ?
                                       OR eventId LIKE ?
                                       OR level LIKE ?
                                       OR platform LIKE ?
                                       OR stacktrace LIKE ?
                                     )
                                     ORDER BY receivedAt DESC
                                     LIMIT ? OFFSET ?"""

const eventDetailSql* = sql"""SELECT eventId, errorType, message, level, platform, receivedAt, stacktrace
                              FROM SentryEvent
                              WHERE project = ? AND eventId = ?"""

const logSummarySql* = sql"""SELECT eventId, errorType, message, level, platform, receivedAt
                             FROM SentryEvent
                             WHERE project = ? AND platform = 'log'
                             ORDER BY receivedAt DESC
                             LIMIT ? OFFSET ?"""

const logSummarySearchSql* = sql"""SELECT eventId, errorType, message, level, platform, receivedAt
                                   FROM SentryEvent
                                   WHERE project = ?
                                   AND platform = 'log'
                                   AND (
                                     errorType LIKE ?
                                     OR message LIKE ?
                                     OR eventId LIKE ?
                                     OR level LIKE ?
                                     OR stacktrace LIKE ?
                                   )
                                   ORDER BY receivedAt DESC
                                   LIMIT ? OFFSET ?"""
