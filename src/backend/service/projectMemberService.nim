import json
import options
import strutils
import std/sysrand
import ../database/dbBackend
import ../database/db
import ./authService
import ./dbService
import ./projectService

proc normalizeMemberName*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    result = "Project member"
  if result.len > 80:
    result = result[0 ..< 80]

proc normalizeMemberEmail*(raw: string): string =
  result = raw.strip().toLowerAscii()
  if result.len == 0:
    raise newException(ValueError, "Email required")
  if result.len > 320:
    raise newException(ValueError, "Email too long")
  if result.find('@') < 1:
    raise newException(ValueError, "Valid email required")

proc normalizeMemberPassword*(raw: string, required: bool): string =
  result = raw
  if result.len == 0 and not required:
    return
  if result.len < 8:
    raise newException(ValueError, "Password must be at least 8 characters")
  if result.len > 256:
    raise newException(ValueError, "Password too long")

proc generateInvitePassword*(): string =
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
  let bytes = urandom(18)
  for value in bytes:
    result.add alphabet[int(value) mod alphabet.len]

proc upsertInvitedUser*(
    db: DbConn,
    name, email: string,
    generatedPassword: var string
): JsonNode =
  let memberName = normalizeMemberName(name)
  let memberEmail = normalizeMemberEmail(email)
  let existing = db.getRow(dbSql"SELECT id FROM users WHERE lower(email) = lower(?)", memberEmail)

  var userId: int
  if existing.isSome:
    userId = existing.get[0].i.int
    db.exec(dbSql"UPDATE users SET name = ?, email = ? WHERE id = ?", memberName, memberEmail, userId)
    generatedPassword = ""
  else:
    generatedPassword = generateInvitePassword()
    var user = newUser(memberName, memberEmail, hashPassword(generatedPassword))
    db.insert(user)
    userId = user.id.int

  %* {"id": $userId, "name": memberName, "email": memberEmail}

proc memberJson*(row: seq[DbValue]): JsonNode =
  %* {
    "id": $row[0].i,
    "name": dbText(row[1]),
    "email": dbText(row[2]),
    "owner": row[3].i != 0
  }

proc listProjectMembers*(db: DbConn, projectDbId: int): seq[JsonNode] =
  for row in db.rows(
    dbSql"""SELECT u.id, u.name, u.email, CASE WHEN p.owner = u.id THEN 1 ELSE 0 END AS ownerFlag
          FROM users u
          JOIN projects p ON p.id = ?
          WHERE u.id = p.owner
             OR EXISTS (
               SELECT 1 FROM user_project_access a
               WHERE a.project = p.id AND a.memberUser = u.id
             )
          ORDER BY ownerFlag DESC, lower(u.name), lower(u.email)""",
    projectDbId
  ):
    result.add memberJson(row)

proc upsertProjectMember*(
    db: DbConn,
    projectId: string,
    ownerId: int,
    name, email: string,
    generatedPassword: var string
): JsonNode =
  let projectInfo = selectOwnerProject(db, projectId, ownerId)
  if projectInfo.isNone:
    raise newException(ValueError, "Project not found")

  let projectDbId = projectInfo.get.dbId
  let invitedUser = upsertInvitedUser(db, name, email, generatedPassword)
  let userId = parseInt(invitedUser["id"].getStr())
  let memberName = invitedUser["name"].getStr()
  let memberEmail = invitedUser["email"].getStr()

  if userId == ownerId:
    return %* {"id": $userId, "name": memberName, "email": memberEmail, "owner": true}

  let access = db.getRow(
    dbSql"SELECT id FROM user_project_access WHERE memberUser = ? AND project = ?",
    userId,
    projectDbId
  )
  if access.isNone:
    var memberUser = User()
    memberUser.id = userId
    var project = Project(publicKey: "", ntfyTopic: "", webhookUrl: "", notificationConfigs: "[]", owner: User())
    project.id = projectDbId
    var grant = newUserProjectAccess(memberUser, project)
    db.insert(grant)

  %* {"id": $userId, "name": memberName, "email": memberEmail, "owner": false}

proc removeProjectMember*(
    db: DbConn,
    projectId: string,
    ownerId: int,
    memberUserId: int
): bool =
  let projectInfo = selectOwnerProject(db, projectId, ownerId)
  if projectInfo.isNone:
    raise newException(ValueError, "Project not found")
  if memberUserId == ownerId:
    raise newException(ValueError, "Project owner cannot be removed")

  let access = db.getRow(
    dbSql"SELECT id FROM user_project_access WHERE project = ? AND memberUser = ?",
    projectInfo.get.dbId,
    memberUserId
  )
  if access.isNone:
    return false

  db.exec(
    dbSql"DELETE FROM user_project_access WHERE project = ? AND memberUser = ?",
    projectInfo.get.dbId,
    memberUserId
  )
  true
