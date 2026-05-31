import norm/model

type
  User* = ref object of Model
    name*: string
    email*: string
    passwordHash*: string

  Project* = ref object of Model
    name*: string
    owner*: User

  UserProjectAccess* = ref object of Model
    user*: User
    project*: Project

  SentryEvent* = ref object of Model
    eventId*: string
    project*: Project
    platform*: string
    level*: string
    errorType*: string
    message*: string
    receivedAt*: int64

proc newUser*(name, email, passwordHash: string): User =
  User(name: name, email: email, passwordHash: passwordHash)

proc newProject*(name: string, owner: User): Project =
  Project(name: name, owner: owner)

proc newUserProjectAccess*(user: User, project: Project): UserProjectAccess =
  UserProjectAccess(user: user, project: project)

proc newSentryEvent*(eventId: string, project: Project, platform, level, errorType, message: string, receivedAt: int64): SentryEvent =
  SentryEvent(
    eventId: eventId,
    project: project,
    platform: platform,
    level: level,
    errorType: errorType,
    message: message,
    receivedAt: receivedAt
  )
