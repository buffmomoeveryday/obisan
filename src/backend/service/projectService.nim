import mummy
import json
import uuid4
import options
import strutils
import std/[locks, tables, times]
import std/sysrand
import ../database/db
import ./notification/ntfy
import ./appSettingsService
import ./dbService
import ./requestService

type ProjectNotificationSettings* = object
  emailEnabled*: bool
  emailToAddrs*: string

const ProjectCacheTtlSecs = 30'i64

type CachedProject = object
  expiresAt: int64
  project: Project

var
  projectCacheLock: Lock
  projectCache = initTable[string, CachedProject]()

initLock(projectCacheLock)

proc parseProjectNotificationSettings*(raw: string): ProjectNotificationSettings =
  if raw.strip().len == 0:
    return
  try:
    let data = parseJson(raw)
    if data.kind == JObject:
      if "emailEnabled" in data:
        result.emailEnabled = data["emailEnabled"].getBool()
      if "emailToAddrs" in data:
        result.emailToAddrs = data["emailToAddrs"].getStr().strip()
  except CatchableError:
    discard

proc projectNotificationSettingsJson*(settings: ProjectNotificationSettings): JsonNode =
  %* {
    "emailEnabled": settings.emailEnabled,
    "emailToAddrs": settings.emailToAddrs
  }

proc projectNotificationConfigsJson*(emailEnabled: bool, emailToAddrs: string): string =
  $(projectNotificationSettingsJson(ProjectNotificationSettings(
    emailEnabled: emailEnabled,
    emailToAddrs: emailToAddrs.strip()
  )))

proc normalizeProjectEmailRecipients*(raw: string): string =
  result = raw.strip()
  if result.len > 2048:
    raise newException(ValueError, "Email recipients are too long")

proc parseProjectDbId*(projectId: string): Option[int] =
  if projectId.len == 0:
    return none[int]()
  try:
    some parseInt(projectId)
  except ValueError:
    none[int]()

proc normalizeProjectName*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    result = "Untitled project"
  if result.len > 80:
    result = result[0 ..< 80]

proc randomProjectSuffix*(): string =
  while true:
    let bytes = urandom(3)
    let value =
      (uint32(bytes[0]) shl 16) or
      (uint32(bytes[1]) shl 8) or
      uint32(bytes[2])
    if value < 16_000_000'u32:
      return align($(value mod 1_000_000'u32), 6, '0')

proc projectNameWithRandomSuffix*(raw: string): string =
  let suffix = randomProjectSuffix()
  let separator = " "
  let maxBaseLen = 80 - separator.len - suffix.len
  result = normalizeProjectName(raw)
  if result.len > maxBaseLen:
    result = result[0 ..< maxBaseLen].strip()
  result &= separator & suffix

proc ensureNtfyTopic*(db: DbConn, dbId: int, projectName, ntfyTopic: string): string =
  let expected = generateNtfyTopic(dbId, projectName)
  if ntfyTopic.len == 0 or ntfyTopic != expected:
    result = expected
    db.exec(dbSql"UPDATE projects SET ntfyTopic = ? WHERE id = ?", result, dbId)
  else:
    result = ntfyTopic

proc selectOwnedProject*(
    db: DbConn, projectId: string, ownerId: int
): Option[tuple[dbId: int, name: string, publicKey: string]] =
  let numericId = parseProjectDbId(projectId)
  if numericId.isSome:
    let row = db.getRow(
      dbSql"""SELECT p.id, p.name, p.publicKey
            FROM projects p
            LEFT JOIN user_project_access a ON a.project = p.id AND a.memberUser = ?
            WHERE p.id = ? AND (p.owner = ? OR a.id IS NOT NULL)""",
      ownerId,
      numericId.get,
      ownerId,
    )
    if row.isSome:
      return some((row.get[0].i.int, dbText(row.get[1]), dbText(row.get[2])))
    return none[tuple[dbId: int, name: string, publicKey: string]]()

  let row = db.getRow(
    dbSql"""SELECT p.id, p.name, p.publicKey
          FROM projects p
          LEFT JOIN user_project_access a ON a.project = p.id AND a.memberUser = ?
          WHERE p.name = ? AND (p.owner = ? OR a.id IS NOT NULL)""",
    ownerId,
    projectId,
    ownerId,
  )
  if row.isNone:
    return none[tuple[dbId: int, name: string, publicKey: string]]()
  some((row.get[0].i.int, dbText(row.get[1]), dbText(row.get[2])))

proc selectOwnerProject*(
    db: DbConn, projectId: string, ownerId: int
): Option[tuple[dbId: int, name: string, publicKey: string]] =
  let numericId = parseProjectDbId(projectId)
  let row =
    if numericId.isSome:
      db.getRow(
        dbSql"SELECT id, name, publicKey FROM projects WHERE id = ? AND owner = ?",
        numericId.get,
        ownerId
      )
    else:
      db.getRow(
        dbSql"SELECT id, name, publicKey FROM projects WHERE name = ? AND owner = ?",
        projectId,
        ownerId
      )
  if row.isNone:
    return none[tuple[dbId: int, name: string, publicKey: string]]()
  some((row.get[0].i.int, dbText(row.get[1]), dbText(row.get[2])))

proc selectProjectByPathId*(db: DbConn, projectIdStr: string): Option[Project] =
  let row = block:
    let numericId = parseProjectDbId(projectIdStr)
    if numericId.isSome:
      db.getRow(
        dbSql"SELECT id, name, publicKey, ntfyTopic, webhookUrl, notificationConfigs FROM projects WHERE id = ?",
        numericId.get,
      )
    else:
      db.getRow(
        dbSql"SELECT id, name, publicKey, ntfyTopic, webhookUrl, notificationConfigs FROM projects WHERE name = ?",
        projectIdStr,
      )

  if row.isNone:
    return none[Project]()

  var projectRecord = Project(
    name: dbText(row.get[1]),
    publicKey: dbText(row.get[2]),
    ntfyTopic: dbText(row.get[3]),
    webhookUrl: dbText(row.get[4]),
    notificationConfigs: dbText(row.get[5]),
    owner: User(),
  )

  projectRecord.id = row.get[0].i
  projectRecord.ntfyTopic = ensureNtfyTopic(
    db, projectRecord.id.int, projectRecord.name, projectRecord.ntfyTopic
  )
  some(projectRecord)

proc selectCachedProjectByPathId*(db: DbConn, projectIdStr: string): Option[Project] =
  let now = epochTime().int64
  withLock projectCacheLock:
    if projectIdStr in projectCache:
      let cached = projectCache[projectIdStr]
      if cached.expiresAt >= now:
        return some(cached.project)
      projectCache.del projectIdStr

  # Load from DB outside the lock to avoid blocking
  let loaded = selectProjectByPathId(db, projectIdStr)
  if loaded.isSome:
    withLock projectCacheLock:
      projectCache[projectIdStr] = CachedProject(
        expiresAt: now + ProjectCacheTtlSecs,
        project: loaded.get
      )
  loaded

proc invalidateProjectCache*(projectIdStr: string = "") =
  withLock projectCacheLock:
    if projectIdStr.len == 0:
      projectCache.clear()
    else:
      projectCache.del projectIdStr

proc ensurePublicKey*(db: DbConn, name, publicKey: string): string =
  if publicKey.len > 0:
    return publicKey
  result = ($uuid4()).replace("-", "")
  db.exec(dbSql"UPDATE projects SET publicKey = ? WHERE name = ?", result, name)

proc projectToJson*(request: Request, project: Project): JsonNode =
  let settings = loadAppSettings()
  let notificationSettings = parseProjectNotificationSettings(project.notificationConfigs)
  %*{
    "id": $project.id,
    "name": project.name,
    "publicKey": project.publicKey,
    "ntfyTopic": project.ntfyTopic,
    "ntfyUrl": ntfySubscribeUrl(project.ntfyTopic, settings.ntfyServerUrl),
    "webhookUrl": project.webhookUrl,
    "emailEnabled": notificationSettings.emailEnabled,
    "emailToAddrs": notificationSettings.emailToAddrs,
    "dsn": buildProjectDsn(request, project.publicKey, $project.id),
  }

proc projectListItemJson*(
    request: Request,
    dbId: int64,
    name, publicKey, ntfyTopic, webhookUrl: string,
    notificationConfigs: string,
    issueCount: int64,
    ntfyServerUrl: string = "https://ntfy.sh",
): JsonNode =
  let notificationSettings = parseProjectNotificationSettings(notificationConfigs)
  %*{
    "id": $dbId,
    "name": name,
    "publicKey": publicKey,
    "ntfyTopic": ntfyTopic,
    "ntfyUrl": ntfySubscribeUrl(ntfyTopic, ntfyServerUrl),
    "webhookUrl": webhookUrl,
    "emailEnabled": notificationSettings.emailEnabled,
    "emailToAddrs": notificationSettings.emailToAddrs,
    "issueCount": issueCount,
    "dsn": buildProjectDsn(request, publicKey, $dbId),
  }
