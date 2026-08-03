import norm/[model, pragmas]

type
  User* {.tableName: "users".} = ref object of Model
    name*: string
    email*: string
    passwordHash*: string

  Project* {.tableName: "projects".} = ref object of Model
    name*: string
    publicKey*: string
    ntfyTopic*: string
    webhookUrl*: string
    notificationConfigs*: string
    owner*: User

  UserProjectAccess* {.tableName: "user_project_access".} = ref object of Model
    memberUser*: User
    project*: Project

  SentryEvent* {.tableName: "sentry_events".} = ref object of Model
    eventId*: string
    project*: Project
    platform*: string
    level*: string
    errorType*: string
    message*: string
    stacktrace*: string
    receivedAt*: int64

  ProjectMetric* {.tableName: "project_metrics".} = ref object of Model
    project*: Project
    name*: string
    metricType*: string
    value*: float
    unit*: string
    tagsJson*: string
    receivedAt*: int64

proc newUser*(name, email, passwordHash: string): User =
  User(name: name, email: email, passwordHash: passwordHash)

proc newProject*(
  name, publicKey, ntfyTopic: string,
  owner: User,
  webhookUrl: string = "",
  notificationConfigs: string = "[]"
): Project =
  Project(
    name: name,
    publicKey: publicKey,
    ntfyTopic: ntfyTopic,
    webhookUrl: webhookUrl,
    notificationConfigs: notificationConfigs,
    owner: owner
  )

proc newUserProjectAccess*(user: User, project: Project): UserProjectAccess =
  UserProjectAccess(memberUser: user, project: project)

proc newSentryEvent*(eventId: string, project: Project, platform, level, errorType, message, stacktrace: string, receivedAt: int64): SentryEvent =
  SentryEvent(
    eventId: eventId,
    project: project,
    platform: platform,
    level: level,
    errorType: errorType,
    message: message,
    stacktrace: stacktrace,
    receivedAt: receivedAt
  )

proc newProjectMetric*(project: Project, name, metricType: string, value: float, unit, tagsJson: string, receivedAt: int64): ProjectMetric =
  ProjectMetric(
    project: project,
    name: name,
    metricType: metricType,
    value: value,
    unit: unit,
    tagsJson: tagsJson,
    receivedAt: receivedAt
  )
