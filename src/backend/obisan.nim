import mummy, mummy/routers, chronicles, cligen
import quee

import ./database/db
import ./handlers/sentry
import ./utils/http


proc serveIndex(request: Request) =
  const index = staticRead("/frontend/index.html")
  request.respond(200, newHtmlHeaders(), index)

proc startServer(port: int = 8080, dbPath: string = "observability.db",taskDbPath: string = "./obisanTasks",poolSize:int = 8) =
  initDatabase(dbPath, poolSize)

  info "Task queue database", path = taskDbPath
  initQuee(taskDbPath,queues = ["default", "urgent", "notifications"])

  var router: Router
  router.get("/", serveIndex)
  router.post("/api/generate-project/", toGcsafeHandler(generateProjectId))
  router.post("/api/@id/envelope/", toGcsafeHandler(handleSentryEnvelope))

  info "Task queue starting..."
  startQuee()

  let server = newServer(router)
  info "Observability engine rolling...", listeningOnPort = port
  server.serve(Port(port))

when isMainModule:
  dispatch startServer
