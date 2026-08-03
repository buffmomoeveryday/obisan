import std/[json, os, strutils, algorithm, options]
import quee
import limdb

const
  MonitorKeyPrefix* = "mon:"
  ProjectIndexPrefix* = "proj:"
  ProjectListPrefix* = "projlist:"
  HistoryKeyPrefix* = "hist:"
  HistoryIndexPrefix* = "histidx:"
  MaxHistoryPerMonitor* = 200
  JobKeyPrefix* = "v2|"
  UptimeTaskName* = "checkUptimeMonitor"

var uptimeStorePath* = ""
var cachedUptimeDb: Database[string, string]
var cachedUptimeDbReady = false

proc initUptimeStore*(basePath: string) =
  uptimeStorePath = basePath / "uptime-store"
  createDir(uptimeStorePath)
  cachedUptimeDb = openQueueDb(uptimeStorePath)
  cachedUptimeDbReady = true

proc storeDb(): Database[string, string] =
  if uptimeStorePath.len == 0:
    raise newException(ValueError, "Uptime store not initialized")
  if not cachedUptimeDbReady:
    cachedUptimeDb = openQueueDb(uptimeStorePath)
    cachedUptimeDbReady = true
  cachedUptimeDb

proc monitorKey(monitorId: string): string =
  MonitorKeyPrefix & monitorId

proc projectIndexKey(projectId, monitorId: string): string =
  ProjectIndexPrefix & projectId & ":" & monitorId

proc projectListKey(projectId: string): string =
  ProjectListPrefix & projectId

proc historyKey(monitorId: string, checkedAt: int64): string =
  HistoryKeyPrefix & monitorId & ":" & $checkedAt

proc historyIndexKey(monitorId: string): string =
  HistoryIndexPrefix & monitorId

proc readIdList(t: Transaction[string, string], key: string): seq[string] =
  if key notin t:
    return @[]
  let data = parseJson(t[key])
  if data.kind != JArray:
    return @[]
  for item in data:
    if item.kind == JString:
      result.add item.getStr()

proc writeIdList(t: Transaction[string, string], key: string, ids: seq[string]) =
  var arr = newJArray()
  for id in ids:
    arr.add %id
  t[key] = $arr

proc addToProjectList(t: Transaction[string, string], projectId, monitorId: string) =
  let key = projectListKey(projectId)
  var ids = readIdList(t, key)
  if monitorId notin ids:
    ids.add monitorId
    ids.sort()
    writeIdList(t, key, ids)

proc removeFromProjectList(t: Transaction[string, string], projectId, monitorId: string) =
  let key = projectListKey(projectId)
  var ids = readIdList(t, key)
  var next: seq[string] = @[]
  for id in ids:
    if id != monitorId:
      next.add id
  writeIdList(t, key, next)

proc rebuildProjectList(t: Transaction[string, string], projectId: string): seq[string] =
  let prefix = ProjectIndexPrefix & projectId & ":"
  for key, _ in t.pairs:
    if key.startsWith(prefix):
      result.add key[prefix.len .. ^1]
  result.sort()
  writeIdList(t, projectListKey(projectId), result)

proc readHistoryIndex(t: Transaction[string, string], monitorId: string): seq[int64] =
  let key = historyIndexKey(monitorId)
  if key notin t:
    return @[]
  let data = parseJson(t[key])
  if data.kind != JArray:
    return @[]
  for item in data:
    if item.kind == JInt:
      result.add item.getInt().int64

proc writeHistoryIndex(t: Transaction[string, string], monitorId: string, timestamps: seq[int64]) =
  var arr = newJArray()
  for ts in timestamps:
    arr.add %ts
  t[historyIndexKey(monitorId)] = $arr

proc rebuildHistoryIndex(t: Transaction[string, string], monitorId: string): seq[int64] =
  let prefix = HistoryKeyPrefix & monitorId & ":"
  for key, _ in t.pairs:
    if key.startsWith(prefix):
      let tsStr = key[prefix.len .. ^1]
      try:
        result.add parseInt(tsStr).int64
      except ValueError:
        discard
  result.sort(proc(x, y: int64): int = cmp(y, x))
  if result.len > MaxHistoryPerMonitor:
    result.setLen(MaxHistoryPerMonitor)
  writeHistoryIndex(t, monitorId, result)

proc projectMonitorIds(t: Transaction[string, string], projectId: string): seq[string] =
  let listKey = projectListKey(projectId)
  result = readIdList(t, listKey)
  if result.len == 0:
    result = rebuildProjectList(t, projectId)

proc monitorHistoryIndex(t: Transaction[string, string], monitorId: string): seq[int64] =
  result = readHistoryIndex(t, monitorId)
  if result.len == 0:
    let prefix = HistoryKeyPrefix & monitorId & ":"
    var found = false
    for key, _ in t.pairs:
      if key.startsWith(prefix):
        found = true
        break
    if found:
      result = rebuildHistoryIndex(t, monitorId)

proc saveMonitorDoc*(doc: JsonNode) =
  let id = doc["id"].getStr()
  let projectId = doc["projectId"].getStr()
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      t[monitorKey(id)] = $doc
      t[projectIndexKey(projectId, id)] = ""
      addToProjectList(t, projectId, id)

proc getMonitorDoc*(monitorId: string): Option[JsonNode] =
  let db = storeDb()
  var raw = ""
  withQueeDbLock:
    db.withTransaction t:
      if monitorKey(monitorId) in t:
        raw = t[monitorKey(monitorId)]
  if raw.len == 0:
    none[JsonNode]()
  else:
    some(parseJson(raw))

proc getMonitorForProject*(monitorId, projectId: string): Option[JsonNode] =
  let doc = getMonitorDoc(monitorId)
  if doc.isNone:
    return none[JsonNode]()
  if doc.get["projectId"].getStr() != projectId:
    return none[JsonNode]()
  doc

proc listMonitorsForProject*(projectId: string): seq[JsonNode] =
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      let ids = projectMonitorIds(t, projectId)
      for id in ids:
        let key = monitorKey(id)
        if key in t:
          result.add parseJson(t[key])

proc listAllEnabledMonitors*(): seq[JsonNode] =
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      var monitorIds: seq[string] = @[]
      for key, _ in t.pairs:
        if not key.startsWith(ProjectListPrefix):
          continue
        for id in readIdList(t, key):
          if id notin monitorIds:
            monitorIds.add id
      for id in monitorIds:
        let key = monitorKey(id)
        if key notin t:
          continue
        let doc = parseJson(t[key])
        if doc["enabled"].getBool():
          result.add doc

proc deleteMonitorData*(monitorId: string) =
  var projectId = ""
  let existing = getMonitorDoc(monitorId)
  if existing.isSome:
    projectId = existing.get["projectId"].getStr()

  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      if projectId.len > 0:
        removeFromProjectList(t, projectId, monitorId)
        let idx = projectIndexKey(projectId, monitorId)
        if idx in t:
          t.del(idx)

      let mon = monitorKey(monitorId)
      if mon in t:
        t.del(mon)

      let timestamps = readHistoryIndex(t, monitorId)
      for ts in timestamps:
        let hk = historyKey(monitorId, ts)
        if hk in t:
          t.del(hk)
      let hidx = historyIndexKey(monitorId)
      if hidx in t:
        t.del(hidx)

proc appendCheckDoc*(monitorId: string, doc: JsonNode) =
  let checkedAt = doc["checkedAt"].getInt().int64
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      t[historyKey(monitorId, checkedAt)] = $doc
      var timestamps = readHistoryIndex(t, monitorId)
      if timestamps.len == 0:
        let prefix = HistoryKeyPrefix & monitorId & ":"
        for key, _ in t.pairs:
          if key.startsWith(prefix) and key != historyKey(monitorId, checkedAt):
            timestamps = rebuildHistoryIndex(t, monitorId)
            break
      timestamps.insert(checkedAt)
      while timestamps.len > MaxHistoryPerMonitor:
        let dropped = timestamps.pop()
        let hk = historyKey(monitorId, dropped)
        if hk in t:
          t.del(hk)
      writeHistoryIndex(t, monitorId, timestamps)

proc listCheckDocs*(monitorId: string, limit, offset: int): seq[JsonNode] =
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      let timestamps = monitorHistoryIndex(t, monitorId)
      if offset >= timestamps.len:
        return
      let endIdx = min(offset + limit - 1, timestamps.len - 1)
      for i in offset .. endIdx:
        let hk = historyKey(monitorId, timestamps[i])
        if hk in t:
          result.add parseJson(t[hk])

proc countCheckDocs*(monitorId: string): int =
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      result = monitorHistoryIndex(t, monitorId).len

proc jobMatchesMonitor(payload: JsonNode, monitorId: string): bool =
  if payload["taskName"].getStr() != UptimeTaskName:
    return false
  let args = payload["args"]
  if args.kind == JObject and "monitorId" in args:
    return args["monitorId"].getStr() == monitorId
  args.kind == JArray and args.len > 0 and args[0].getStr() == monitorId

proc cancelUptimeJobs*(monitorId: string) =
  let queuePath = dbPath("uptime")
  let db = openQueueDb(queuePath)
  var deletes: seq[string] = @[]
  withQueeDbLock:
    db.withTransaction t:
      for key, val in t.pairs:
        if not key.startsWith(JobKeyPrefix):
          continue
        let payload = parseJson(val)
        if jobMatchesMonitor(payload, monitorId):
          deletes.add key
      for key in deletes:
        t.del(key)

proc hasUptimeJob*(monitorId: string): bool =
  let queuePath = dbPath("uptime")
  let db = openQueueDb(queuePath)
  result = false
  withQueeDbLock:
    db.withTransaction t:
      for key, val in t.pairs:
        if not key.startsWith(JobKeyPrefix):
          continue
        if jobMatchesMonitor(parseJson(val), monitorId):
          result = true
          break

proc rebuildStoreIndexes*() =
  let db = storeDb()
  withQueeDbLock:
    db.withTransaction t:
      var projects: seq[string] = @[]
      for key, _ in t.pairs:
        if key.startsWith(ProjectIndexPrefix):
          let rest = key[ProjectIndexPrefix.len .. ^1]
          let colon = rest.find(':')
          if colon >= 0:
            let projectId = rest[0 ..< colon]
            if projectId notin projects:
              projects.add projectId
      for projectId in projects:
        discard rebuildProjectList(t, projectId)

      var monitors: seq[string] = @[]
      for key, _ in t.pairs:
        if key.startsWith(MonitorKeyPrefix):
          monitors.add key[MonitorKeyPrefix.len .. ^1]
      for monitorId in monitors:
        let prefix = HistoryKeyPrefix & monitorId & ":"
        for key, _ in t.pairs:
          if key.startsWith(prefix):
            discard rebuildHistoryIndex(t, monitorId)
            break
