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

var consoleLog = newConsoleLogger()
addHandler(consoleLog)

var databaseConnection*: DbConn
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
    db.createTables(Project(owner: User()))
    db.createTables(UserProjectAccess(user: User(), project: Project(owner: User())))
    db.createTables(SentryEvent(project: Project(owner: User())))
