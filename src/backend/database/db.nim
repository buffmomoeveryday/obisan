
import chronicles
import logging

import ./dbBackend
import ./models

export dbBackend
export User
export newUser
export Project
export newProject
export UserProjectAccess
export newUserProjectAccess
export SentryEvent
export newSentryEvent
export ProjectMetric
export newProjectMetric


var
  dbPool*: Pool[DbConn]
  configuredDbPath = ""

proc openConfiguredDb(): DbConn {.noSideEffect, gcsafe.} =
  var conn: DbConn
  {.cast(noSideEffect), cast(gcsafe).}:
    conn = open(configuredDbPath, "", "", "")
    conn.exec(dbSql"PRAGMA journal_mode=WAL;")
    conn.exec(dbSql"PRAGMA busy_timeout=5000;")
    conn.exec(dbSql"PRAGMA synchronous=NORMAL;")
    conn.exec(dbSql"PRAGMA temp_store=MEMORY;")
    conn.exec(dbSql"PRAGMA mmap_size=268435456;")
    conn.exec(dbSql"PRAGMA journal_size_limit=27103364;")
    conn.exec(dbSql"PRAGMA cache_size=-64000;")
  return conn

proc addColumnIfMissing(db: DbConn, tableName, columnName, columnDefinition: string) =
  try:
    db.exec(dbSql("ALTER TABLE " & tableName & " ADD COLUMN " & columnName & " " & columnDefinition))
  except DbError:
    discard

template initSchemaStep(label: string, body: untyped) =
  try:
    debug "Initializing schema object", name = label
    body
  except DbError as e:
    error "Failed to initialize schema object", name = label, errorMsg = e.msg
    raise


proc initDatabase*(dbPath: string, poolSize: int) =
  info "Initializing database pool...",
    backend = "sqlite",
    path = dbPath,
    size = poolSize

  configuredDbPath = dbPath
  dbPool = newPool[DbConn](poolSize, openConfiguredDb)

  withDb dbPool:
    initSchemaStep "users":
      db.createTables(User())
    initSchemaStep "projects":
      db.createTables(Project(publicKey: "", ntfyTopic: "", webhookUrl: "", notificationConfigs: "[]", owner: User()))
    initSchemaStep "projects optional columns":
      db.addColumnIfMissing("projects", "publicKey", "TEXT NOT NULL DEFAULT ''")
      db.addColumnIfMissing("projects", "ntfyTopic", "TEXT NOT NULL DEFAULT ''")
      db.addColumnIfMissing("projects", "webhookUrl", "TEXT NOT NULL DEFAULT ''")
      db.addColumnIfMissing("projects", "notificationConfigs", "TEXT NOT NULL DEFAULT '[]'")
    initSchemaStep "app_settings":
      db.exec(dbSql"CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')")
    initSchemaStep "user_project_access":
      db.createTables(UserProjectAccess(memberUser: User(), project: Project(publicKey: "", ntfyTopic: "", webhookUrl: "", notificationConfigs: "[]", owner: User())))
    initSchemaStep "sentry_events":
      db.createTables(SentryEvent(project: Project(publicKey: "", ntfyTopic: "", webhookUrl: "", notificationConfigs: "[]", owner: User()), stacktrace: ""))
    initSchemaStep "sentry_events optional columns":
      db.addColumnIfMissing("sentry_events", "stacktrace", "TEXT NOT NULL DEFAULT ''")
    initSchemaStep "project_metrics":
      db.createTables(ProjectMetric(project: Project(publicKey: "", ntfyTopic: "", webhookUrl: "", notificationConfigs: "[]", owner: User()), tagsJson: ""))
