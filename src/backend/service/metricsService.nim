import json
import options
import strutils
import times

import ../database/db
import ./dbService
import ./queryService
import ./projectService

type MetricInput* = object
  name: string
  metricType: string
  value: float
  unit: string
  tagsJson: string
  receivedAt: int64

proc nodeText(data: JsonNode, keys: varargs[string]): string =
  for key in keys:
    if data.kind == JObject and key in data:
      case data[key].kind
      of JString:
        return data[key].getStr()
      of JInt, JFloat, JBool:
        return $data[key]
      else:
        discard
  ""

proc nodeTextDefault(data: JsonNode, defaultValue: string, keys: varargs[string]): string =
  result = nodeText(data, keys)
  if result.len == 0:
    result = defaultValue

proc nodeFloat(data: JsonNode, keys: varargs[string]): Option[float] =
  for key in keys:
    if data.kind == JObject and key in data:
      case data[key].kind
      of JFloat:
        return some(data[key].getFloat())
      of JInt:
        return some(data[key].getInt().float)
      of JString:
        try:
          return some(parseFloat(data[key].getStr()))
        except ValueError:
          discard
      else:
        discard
  none[float]()

proc nodeUnixTime(data: JsonNode): int64 =
  if data.kind == JObject:
    let raw = nodeFloat(data, "timestamp", "time", "receivedAt", "ts")
    if raw.isSome:
      let value = raw.get
      if value > 9_999_999_999'f64:
        return int64(value / 1000'f64)
      return int64(value)
  getTime().toUnix()

proc normalizeMetricName(raw: string): string =
  result = raw.strip()
  if result.len > 120:
    result = result[0 ..< 120]

proc normalizeMetricType(raw: string): string =
  let lowered = raw.strip().toLowerAscii()
  case lowered
  of "counter", "count":
    "counter"
  of "distribution", "histogram", "timer":
    "distribution"
  else:
    "gauge"

proc tagsForMetric(data: JsonNode): string =
  if data.kind == JObject:
    if "tags" in data and data["tags"].kind == JObject:
      return $data["tags"]
    if "attributes" in data and data["attributes"].kind == JObject:
      return $data["attributes"]
  "{}"

proc parseMetricObject(data: JsonNode, defaultTimestamp: int64): Option[MetricInput] =
  if data.kind != JObject:
    return none[MetricInput]()

  let name = normalizeMetricName(data.nodeText("name", "metric", "key"))
  let value = data.nodeFloat("value", "usage", "amount")
  if name.len == 0 or value.isNone:
    return none[MetricInput]()

  let metricType = normalizeMetricType(data.nodeTextDefault("gauge", "type", "metricType"))
  let timestamp =
    if data.kind == JObject and ("timestamp" in data or "time" in data or "receivedAt" in data or "ts" in data):
      data.nodeUnixTime()
    else:
      defaultTimestamp

  some(MetricInput(
    name: name,
    metricType: metricType,
    value: value.get,
    unit: data.nodeText("unit"),
    tagsJson: tagsForMetric(data),
    receivedAt: timestamp
  ))

proc parseFlatSystemMetrics(data: JsonNode, defaultTimestamp: int64): seq[MetricInput] =
  if data.kind != JObject:
    return @[]

  let timestamp = data.nodeUnixTime()
  let tags =
    if "tags" in data and data["tags"].kind == JObject:
      $data["tags"]
    elif "host" in data:
      $(%* {"host": data.nodeText("host")})
    else:
      "{}"

  for key in ["cpu", "cpuPercent", "cpu_percent", "ram", "memory", "memoryPercent", "memory_percent", "disk", "diskPercent", "disk_percent", "load", "loadAverage"]:
    let value = data.nodeFloat(key)
    if value.isSome:
      let name =
        case key
        of "cpu", "cpuPercent", "cpu_percent":
          "system.cpu.percent"
        of "ram", "memory", "memoryPercent", "memory_percent":
          "system.memory.percent"
        of "disk", "diskPercent", "disk_percent":
          "system.disk.percent"
        else:
          "system.load.average"
      result.add MetricInput(
        name: name,
        metricType: "gauge",
        value: value.get,
        unit: if name.endsWith(".percent"): "percent" else: "",
        tagsJson: tags,
        receivedAt: timestamp
      )

proc parseMetricsPayload*(body: string): seq[MetricInput] =
  if body.len == 0:
    raise newException(ValueError, "Request body required")

  let data = parseJson(body)
  let defaultTimestamp = data.nodeUnixTime()

  if data.kind == JObject and "metrics" in data and data["metrics"].kind == JArray:
    for item in data["metrics"]:
      let metric = parseMetricObject(item, defaultTimestamp)
      if metric.isSome:
        result.add metric.get
  elif data.kind == JArray:
    for item in data:
      let metric = parseMetricObject(item, defaultTimestamp)
      if metric.isSome:
        result.add metric.get
  else:
    let metric = parseMetricObject(data, defaultTimestamp)
    if metric.isSome:
      result.add metric.get
    else:
      result = parseFlatSystemMetrics(data, defaultTimestamp)

  if result.len == 0:
    raise newException(ValueError, "No valid metrics found")
  if result.len > 500:
    raise newException(ValueError, "Too many metrics in one request")

proc metricsToQueuePayload*(metrics: openArray[MetricInput]): string =
  result = "["
  for index, metric in metrics:
    if index > 0:
      result.add ","
    result.add "{"
    result.add "\"name\":" & escapeJson(metric.name) & ","
    result.add "\"metricType\":" & escapeJson(metric.metricType) & ","
    result.add "\"value\":" & $metric.value & ","
    result.add "\"unit\":" & escapeJson(metric.unit) & ","
    result.add "\"tagsJson\":" & escapeJson(metric.tagsJson) & ","
    result.add "\"receivedAt\":" & $metric.receivedAt
    result.add "}"
  result.add "]"

proc parseQueuedMetricsNode*(data: JsonNode): seq[MetricInput] =
  if data.kind != JArray:
    raise newException(ValueError, "Queued metrics payload must be an array")

  for item in data:
    if item.kind != JObject:
      continue
    let value = item.nodeFloat("value")
    if value.isNone:
      continue
    result.add MetricInput(
      name: normalizeMetricName(item.nodeText("name")),
      metricType: normalizeMetricType(item.nodeTextDefault("gauge", "metricType", "type")),
      value: value.get,
      unit: item.nodeText("unit"),
      tagsJson: item.nodeTextDefault("{}", "tagsJson"),
      receivedAt: int64(item.nodeFloat("receivedAt").get(getTime().toUnix().float))
    )

  if result.len == 0:
    raise newException(ValueError, "No queued metrics found")
  if result.len > 500:
    raise newException(ValueError, "Too many metrics in one queued payload")

proc parseQueuedMetricsPayload*(body: string): seq[MetricInput] =
  if body.len == 0:
    raise newException(ValueError, "Queued metrics payload required")
  parseQueuedMetricsNode(parseJson(body))

proc saveMetricsBatch*(projectDbId: int, metrics: openArray[MetricInput]): int =
  var projectName = ""

  withDb dbPool:
    let projectRow = db.getRow(dbSql"SELECT name FROM projects WHERE id = ?", projectDbId)
    if projectRow.isSome:
      projectName = dbText(projectRow.get[0])
    db.exec(dbSql"BEGIN")
    try:
      for metric in metrics:
        db.exec(
          dbSql"""INSERT INTO project_metrics
                (project, name, metricType, value, unit, tagsJson, receivedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
          projectDbId,
          metric.name,
          metric.metricType,
          metric.value,
          metric.unit,
          metric.tagsJson,
          metric.receivedAt
        )
        inc result
      db.exec(dbSql"COMMIT")
    except CatchableError:
      db.exec(dbSql"ROLLBACK")
      raise

  # Notifications for metrics ingestion are intentionally disabled —
  # they would flood notification channels under normal/high throughput.

proc saveMetricsPayload*(projectDbId: int, body: string): int =
  let metrics = parseMetricsPayload(body)
  saveMetricsBatch(projectDbId, metrics)


proc countProjectMetrics*(db: DbConn, projectDbId: int, search: string, sinceUnix: int64 = 0): int =
  let row =
    if search.len == 0 and sinceUnix <= 0:
      db.getRow(dbSql"SELECT COUNT(*) FROM project_metrics WHERE project = ?", projectDbId)
    elif search.len == 0:
      db.getRow(
        dbSql"SELECT COUNT(*) FROM project_metrics WHERE project = ? AND receivedAt >= ?",
        projectDbId,
        sinceUnix
      )
    elif sinceUnix <= 0:
      let pattern = likePattern(search)
      db.getRow(
        dbSql"""SELECT COUNT(*) FROM project_metrics
              WHERE project = ?
              AND (
                name LIKE ?
                OR metricType LIKE ?
                OR unit LIKE ?
                OR tagsJson LIKE ?
              )""",
        projectDbId,
        pattern,
        pattern,
        pattern,
        pattern
      )
    else:
      let pattern = likePattern(search)
      db.getRow(
        dbSql"""SELECT COUNT(*) FROM project_metrics
              WHERE project = ?
              AND receivedAt >= ?
              AND (
                name LIKE ?
                OR metricType LIKE ?
                OR unit LIKE ?
                OR tagsJson LIKE ?
              )""",
        projectDbId,
        sinceUnix,
        pattern,
        pattern,
        pattern,
        pattern
      )
  if row.isNone:
    0
  else:
    row.get[0].i.int

proc metricSummaryJson*(row: seq[DbValue]): JsonNode =
  %* {
    "id": $row[0].i,
    "name": dbText(row[1]),
    "type": dbText(row[2]),
    "value": row[3].f,
    "unit": dbText(row[4]),
    "tags": dbText(row[5]),
    "receivedAt": formatUnixTime(row[6].i.int64)
  }

proc metricSummaryJsonText*(row: seq[DbValue]): string =
  result = "{"
  result &= "\"id\":" & escapeJson($row[0].i) & ","
  result &= "\"name\":" & escapeJson(dbText(row[1])) & ","
  result &= "\"type\":" & escapeJson(dbText(row[2])) & ","
  result &= "\"value\":" & $row[3].f & ","
  result &= "\"unit\":" & escapeJson(dbText(row[4])) & ","
  result &= "\"tags\":" & escapeJson(dbText(row[5])) & ","
  result &= "\"receivedAt\":" & escapeJson(formatUnixTime(row[6].i.int64))
  result &= "}"

const metricSummarySql* = dbSql"""SELECT id, name, metricType, value, unit, tagsJson, receivedAt
                                FROM project_metrics
                                WHERE project = ?
                                ORDER BY receivedAt DESC, id DESC
                                LIMIT ? OFFSET ?"""

const metricSummarySinceSql* = dbSql"""SELECT id, name, metricType, value, unit, tagsJson, receivedAt
                                     FROM project_metrics
                                     WHERE project = ?
                                     AND receivedAt >= ?
                                     ORDER BY receivedAt DESC, id DESC
                                     LIMIT ? OFFSET ?"""

const metricSummarySearchSql* = dbSql"""SELECT id, name, metricType, value, unit, tagsJson, receivedAt
                                      FROM project_metrics
                                      WHERE project = ?
                                      AND (
                                        name LIKE ?
                                        OR metricType LIKE ?
                                        OR unit LIKE ?
                                        OR tagsJson LIKE ?
                                      )
                                      ORDER BY receivedAt DESC, id DESC
                                      LIMIT ? OFFSET ?"""

const metricSummarySearchSinceSql* = dbSql"""SELECT id, name, metricType, value, unit, tagsJson, receivedAt
                                           FROM project_metrics
                                           WHERE project = ?
                                           AND receivedAt >= ?
                                           AND (
                                             name LIKE ?
                                             OR metricType LIKE ?
                                             OR unit LIKE ?
                                             OR tagsJson LIKE ?
                                           )
                                           ORDER BY receivedAt DESC, id DESC
                                           LIMIT ? OFFSET ?"""

const metricSummaryWindowSql* = dbSql"""SELECT id, name, metricType, value, unit, tagsJson, receivedAt
                                      FROM project_metrics
                                      WHERE project = ?
                                      AND receivedAt >= ?
                                      AND receivedAt <= ?
                                      ORDER BY receivedAt DESC, id DESC
                                      LIMIT ? OFFSET ?"""
