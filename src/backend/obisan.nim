import mummy, mummy/routers, chronicles, cligen
import quee

import ./database/db
import ./handlers/sentry
import ./handlers/settings
import ./handlers/projectMembers
import ./handlers/users
import ./handlers/uptime
import ./utils/http
import ./utils/runtimeDeps
import ./service/sentryService
import ./service/uptimeStore
import ./tasks/tasks


proc serveIndex(request: Request) =
  info "Serving index"
  const index = staticRead("../frontend/index.html")
  request.respond(200, newHtmlHeaders(), index)

proc serveAppJs(request: Request) =
  info "Serving js"
  const appJs = staticRead("../../bin/app.js")
  request.respond(200, newJsHeaders(), appJs)

proc startServer(port: int = 8080, dbPath: string = "observability.db", taskDbPath: string = "./obisanTasks", poolSize: int = 32) =
  requireRuntimeDependencies()
  initDatabase(dbPath, poolSize)

  info "Task queue database", path = taskDbPath
  initQuee(
    taskDbPath,
    queues = ["default", "urgent", "uptime"],
    workerConcurrency = 1
  )
  initUptimeStore(taskDbPath)
  startMetricsIngestionWorker()
  startSentryIngestionWorker()

  var router: Router
  router.get("/", serveIndex)
  router.get("/app.js", serveAppJs)
  router.get("/api/setup-status/", toGcsafeHandler(getSetupStatus))
  router.post("/api/register/", toGcsafeHandler(registerUser))
  router.post("/api/login/", toGcsafeHandler(loginUser))
  router.get("/api/profile/", toGcsafeHandler(getProfile))
  router.patch("/api/profile/", toGcsafeHandler(updateProfile))
  router.get("/api/settings/", toGcsafeHandler(getSettings))
  router.patch("/api/settings/", toGcsafeHandler(updateSettings))
  router.get("/api/projects/", toGcsafeHandler(listProjects))
  router.get("/api/projects/@id/events/", toGcsafeHandler(listProjectEvents))
  router.get("/api/projects/@id/members/", toGcsafeHandler(listProjectMembersHandler))
  router.post("/api/projects/@id/members/", toGcsafeHandler(upsertProjectMemberHandler))
  router.delete("/api/projects/@id/members/@memberId/", toGcsafeHandler(removeProjectMemberHandler))
  router.post("/api/invites/", toGcsafeHandler(inviteUserHandler))
  router.get("/api/projects/@id/events/@eventId/", toGcsafeHandler(getProjectEvent))
  router.get("/api/projects/@id/logs/", toGcsafeHandler(listProjectLogs))
  router.get("/api/projects/@id/metrics/", toGcsafeHandler(listProjectMetrics))
  router.post("/api/projects/@id/metrics/", toGcsafeHandler(ingestProjectMetrics))
  router.post("/api/projects/@id/events/delete/", toGcsafeHandler(deleteProjectEvents))
  router.delete("/api/projects/@id/events/@eventId/", toGcsafeHandler(deleteProjectEvent))
  router.patch("/api/projects/@id/", toGcsafeHandler(updateProject))
  router.get("/api/projects/@id/uptime/", toGcsafeHandler(listProjectUptimeMonitors))
  router.post("/api/projects/@id/uptime/", toGcsafeHandler(createProjectUptimeMonitor))
  router.patch("/api/projects/@id/uptime/@monitorId/", toGcsafeHandler(updateProjectUptimeMonitor))
  router.delete("/api/projects/@id/uptime/@monitorId/", toGcsafeHandler(deleteProjectUptimeMonitor))
  router.get("/api/projects/@id/uptime/@monitorId/checks/", toGcsafeHandler(listProjectUptimeChecks))
  router.post("/api/generate-project/", toGcsafeHandler(generateProjectId))
  router.post("/api/@id/envelope/", toGcsafeHandler(handleSentryEnvelope))

  info "Task queue starting..."
  startQuee(concurrency = 4)
  startUptimeScheduler()

  let server = newServer(router)
  info "Observability engine rolling...", listeningOnPort = port
  server.serve(Port(port))

when isMainModule:
  dispatch startServer
