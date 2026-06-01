import mummy
import json
import uuid4
import options
import strutils
import norm/sqlite
import lowdb/sqlite

import ../database/db
import ../utils/ntfy
import ./dbService
import ./requestService

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

proc ensureNtfyTopic*(db: DbConn, dbId: int, projectName, ntfyTopic: string): string =
  let expected = generateNtfyTopic(dbId, projectName)
  if ntfyTopic.len == 0 or ntfyTopic != expected:
    result = expected
    db.exec(sql"UPDATE Project SET ntfyTopic = ? WHERE id = ?", result, dbId)
  else:
    result = ntfyTopic

proc selectOwnedProject*(
  db: DbConn,
  projectId: string,
  ownerId: int
): Option[tuple[dbId: int, name: string, publicKey: string]] =
  let numericId = parseProjectDbId(projectId)
  if numericId.isSome:
    let row = db.getRow(
      sql"SELECT id, name, publicKey FROM Project WHERE id = ? AND owner = ?",
      numericId.get,
      ownerId
    )
    if row.isSome:
      return some((row.get[0].i.int, dbText(row.get[1]), dbText(row.get[2])))
    return none[tuple[dbId: int, name: string, publicKey: string]]()

  let row = db.getRow(
    sql"SELECT id, name, publicKey FROM Project WHERE name = ? AND owner = ?",
    projectId,
    ownerId
  )
  if row.isNone:
    return none[tuple[dbId: int, name: string, publicKey: string]]()
  some((row.get[0].i.int, dbText(row.get[1]), dbText(row.get[2])))

proc selectProjectByPathId*(db: DbConn, projectIdStr: string): Option[Project] =
  let row =
    block:
      let numericId = parseProjectDbId(projectIdStr)
      if numericId.isSome:
        db.getRow(sql"SELECT id, name, publicKey, ntfyTopic FROM Project WHERE id = ?", numericId.get)
      else:
        db.getRow(sql"SELECT id, name, publicKey, ntfyTopic FROM Project WHERE name = ?", projectIdStr)

  if row.isNone:
    return none[Project]()

  var projectRecord = Project(
    name: dbText(row.get[1]),
    publicKey: dbText(row.get[2]),
    ntfyTopic: dbText(row.get[3]),
    owner: User()
  )
  projectRecord.id = row.get[0].i
  projectRecord.ntfyTopic = ensureNtfyTopic(
    db, projectRecord.id.int, projectRecord.name, projectRecord.ntfyTopic
  )
  some(projectRecord)

proc ensurePublicKey*(db: DbConn, name, publicKey: string): string =
  if publicKey.len > 0:
    return publicKey
  result = ($uuid4()).replace("-", "")
  db.exec(sql"UPDATE Project SET publicKey = ? WHERE name = ?", result, name)

proc projectToJson*(request: Request, project: Project): JsonNode =
  %* {
    "id": $project.id,
    "name": project.name,
    "publicKey": project.publicKey,
    "ntfyTopic": project.ntfyTopic,
    "ntfyUrl": ntfySubscribeUrl(project.ntfyTopic),
    "dsn": buildProjectDsn(request, project.publicKey, $project.id)
  }

proc projectListItemJson*(
  request: Request,
  dbId: int64,
  name, publicKey, ntfyTopic: string,
  issueCount: int64
): JsonNode =
  %* {
    "id": $dbId,
    "name": name,
    "publicKey": publicKey,
    "ntfyTopic": ntfyTopic,
    "ntfyUrl": ntfySubscribeUrl(ntfyTopic),
    "issueCount": issueCount,
    "dsn": buildProjectDsn(request, publicKey, $dbId)
  }
