import norm/[model, sqlite, pool]
import chronicles
import logging

import ./models

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

var consoleLog = newConsoleLogger()
addHandler(consoleLog)

var dbPool*: Pool[DbConn]

proc createConnFactory*(dbPath: string): proc(): DbConn =
  return proc(): DbConn =
    let conn = open(dbPath, "", "", "")
    conn.exec(sql"PRAGMA journal_mode=WAL;")
    conn.exec(sql"PRAGMA busy_timeout=5000;")
    conn.exec(sql"PRAGMA synchronous=NORMAL;")
    conn.exec(sql"PRAGMA temp_store=MEMORY;")
    conn.exec(sql"PRAGMA mmap_size=134217728;")
    conn.exec(sql"PRAGMA journal_size_limit=27103364;")
    conn.exec(sql"PRAGMA cache_size=2000;")
    return conn

proc initDatabase*(dbPath: string, poolSize: int) =
  info "Initializing database pool...", path = dbPath, size = poolSize

  dbPool = newPool[DbConn](poolSize, createConnFactory(dbPath))

  withDb dbPool:
    db.createTables(User())
    db.createTables(Project(publicKey: "", ntfyTopic: "", owner: User()))
    try:
      db.exec(sql"ALTER TABLE Project ADD COLUMN publicKey TEXT NOT NULL DEFAULT ''")
    except DbError:
      discard
    try:
      db.exec(sql"ALTER TABLE Project ADD COLUMN ntfyTopic TEXT NOT NULL DEFAULT ''")
    except DbError:
      discard
    db.createTables(UserProjectAccess(user: User(), project: Project(publicKey: "", ntfyTopic: "", owner: User())))
    db.createTables(SentryEvent(project: Project(publicKey: "", ntfyTopic: "", owner: User()), stacktrace: ""))
    try:
      db.exec(sql"ALTER TABLE SentryEvent ADD COLUMN stacktrace TEXT NOT NULL DEFAULT ''")
    except DbError:
      discard
    db.createTables(ProjectMetric(project: Project(publicKey: "", ntfyTopic: "", owner: User()), tagsJson: ""))
