import mummy
import json
import chronicles
import options
import strutils

import ../database/db
import ../utils/http
import ../service/authService
import ../service/appSettingsService
import ../service/notification/email
import ../service/projectMemberService
import ../service/projectService

proc smtpConfigured(settings: AppSettings): bool =
  settings.smtpHost.len > 0 and settings.smtpFromAddr.len > 0

proc inviteEmailBody(projectName, inviterName, invitedName, invitedEmail, password: string): string =
  result = "You have been invited to Obisan"
  if projectName.len > 0:
    result &= " for project " & projectName
  result &= ".\n\n"
  if inviterName.len > 0:
    if projectName.len > 0:
      result &= inviterName & " added you as a project member.\n\n"
    else:
      result &= inviterName & " invited you to the workspace.\n\n"
  result &= "Email: " & invitedEmail & "\n"
  if password.len > 0:
    result &= "Password: " & password & "\n\n"
    result &= "Sign in to start using Obisan.\n"
  else:
    result &= "\nUse your existing Obisan password to sign in.\n"

proc sendInviteEmail(
    settings: AppSettings,
    projectName, inviterName, invitedName, invitedEmail, password: string
) =
  let subject =
    if projectName.len > 0:
      "Obisan invite: " & projectName
    else:
      "Obisan invite"
  sendEmail(
    settings.smtpHost,
    settings.smtpPort,
    settings.smtpUsername,
    settings.smtpPassword,
    settings.smtpFromAddr,
    @[invitedEmail],
    subject,
    inviteEmailBody(projectName, inviterName, invitedName, invitedEmail, password),
    settings.smtpUseTls,
    5000
  )

proc inviteUserHandler*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  try:
    let body = parseJson(request.body)
    let name = if "name" in body: body["name"].getStr() else: ""
    let email = if "email" in body: body["email"].getStr() else: ""
    var invited: JsonNode
    var settings = AppSettings()
    var generatedPassword = ""
    withDb dbPool:
      settings = loadAppSettings(db)
      if not smtpConfigured(settings):
        request.respond(400, newJsonHeaders(), (%* {"error": "SMTP must be configured before inviting users"}).pretty)
        return
      invited = upsertInvitedUser(db, name, email, generatedPassword)
    sendInviteEmail(settings, "", user.get.name, name, invited["email"].getStr(), generatedPassword)
    request.respond(200, newJsonHeaders(), invited.pretty)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to invite user", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to invite user"}).pretty)

proc listProjectMembersHandler*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  try:
    var members = newJArray()
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      for member in listProjectMembers(db, projectInfo.get.dbId):
        add(members, member)
    request.respond(200, newJsonHeaders(), (%* {"members": members}).pretty)
  except CatchableError as e:
    error "Failed to list project members", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list project members"}).pretty)

proc upsertProjectMemberHandler*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  try:
    let body = parseJson(request.body)
    let name = if "name" in body: body["name"].getStr() else: ""
    let email = if "email" in body: body["email"].getStr() else: ""
    var member: JsonNode
    var projectName = ""
    var settings = AppSettings()
    var generatedPassword = ""
    withDb dbPool:
      let projectInfo = selectOwnerProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectName = projectInfo.get.name
      settings = loadAppSettings(db)
      if not smtpConfigured(settings):
        request.respond(400, newJsonHeaders(), (%* {"error": "SMTP must be configured before inviting users"}).pretty)
        return
      member = upsertProjectMember(db, projectId, user.get.id, name, email, generatedPassword)
    sendInviteEmail(settings, projectName, user.get.name, name, member["email"].getStr(), generatedPassword)
    request.respond(200, newJsonHeaders(), member.pretty)
  except ValueError as e:
    let status = if e.msg == "Project not found": 404 else: 400
    request.respond(status, newJsonHeaders(), (%* {"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to save project member", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to save project member"}).pretty)

proc removeProjectMemberHandler*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let memberIdRaw = request.pathParams.getOrDefault("memberId", "")
  if projectId.len == 0 or memberIdRaw.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id and member id required"}).pretty)
    return

  try:
    let memberId = parseInt(memberIdRaw)
    var removed = false
    withDb dbPool:
      removed = removeProjectMember(db, projectId, user.get.id.int, memberId)
    if removed:
      request.respond(200, newJsonHeaders(), (%* {"removed": true}).pretty)
    else:
      request.respond(404, newJsonHeaders(), (%* {"error": "Member access not found"}).pretty)
  except ValueError as e:
    let status = if e.msg == "Project not found": 404 else: 400
    request.respond(status, newJsonHeaders(), (%* {"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to remove project member", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to remove project member"}).pretty)
