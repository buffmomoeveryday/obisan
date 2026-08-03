import quee
import times
import chronicles
import json

import ../service/metricsService
import ../service/uptimeService
import ../service/uptimeStore
import ../service/notification/notificationService

type MetricsIngestJob = object
  projectDbId: int
  payload: string

var
  metricsIngestChannel: Channel[MetricsIngestJob]
  metricsIngestWorker: Thread[void]
  metricsIngestWorkerStarted = false

proc metricsIngestWorkerLoop() {.thread.} =
  while true:
    let job = metricsIngestChannel.recv()
    try:
      let metrics = parseQueuedMetricsPayload(job.payload)
      var saved = 0
      {.cast(gcsafe).}:
        saved = saveMetricsBatch(job.projectDbId, metrics)
      info "Saved project metrics", projectDbId = job.projectDbId, count = saved
    except CatchableError as e:
      error "Failed to save queued project metrics",
        projectDbId = job.projectDbId, errorMsg = e.msg

proc startMetricsIngestionWorker*() =
  if metricsIngestWorkerStarted:
    return
  metricsIngestChannel.open(4096)
  createThread(metricsIngestWorker, metricsIngestWorkerLoop)
  metricsIngestWorkerStarted = true
  info "Metrics ingestion worker started"

# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

task checkUptimeMonitor(monitorId: string):
  queue "uptime"
  executeMonitorCheck(monitorId)

# ---------------------------------------------------------------------------
# Synchronous notification helpers (no quee)
# ---------------------------------------------------------------------------
proc sendNtfyNow*(topic, message, title: string) =
  if topic.len == 0:
    return
  let service = buildProjectNotificationService(topic, "")
  service.notify(NotificationMessage(
    title: title,
    body: message,
    priority: npHigh,
    eventType: "",
    projectId: "",
    projectName: "",
    data: newJNull()
  ))

proc sendWebhookNow*(url, eventType: string, payload: JsonNode) =
  if url.len == 0:
    return
  let service = buildProjectNotificationService("", url)
  service.notify(NotificationMessage(
    title: eventType,
    body: payload.pretty,
    priority: npNormal,
    eventType: eventType,
    projectId: "",
    projectName: "",
    data: payload
  ))

proc enqueueNtfy*(topic, message, title: string) =
  sendNtfyNow(topic, message, title)

proc enqueueWebhook*(url, eventType: string, payload: JsonNode) =
  sendWebhookNow(url, eventType, payload)

# ---------------------------------------------------------------------------
# Metrics — channel-backed worker, avoiding inline request-path writes and LMDB.
# ---------------------------------------------------------------------------

proc enqueueProjectMetrics*(projectDbId: int, payload: string) =
  if not metricsIngestWorkerStarted:
    startMetricsIngestionWorker()
  metricsIngestChannel.send(MetricsIngestJob(projectDbId: projectDbId, payload: payload))

# ---------------------------------------------------------------------------
# Uptime — stays on the LMDB queue (low throughput)
# ---------------------------------------------------------------------------

proc enqueueUptimeMonitor*(monitorId: string, intervalSecs: int) =
  discard checkUptimeMonitor.enqueue(monitorId).every(intervalSecs.seconds).run()

proc resyncUptimeMonitor*(monitorId: string, intervalSecs: int) =
  cancelUptimeJobs(monitorId)
  enqueueUptimeMonitor(monitorId, intervalSecs)

proc syncUptimeJobsOnStartup*() =
  for doc in listAllEnabledMonitors():
    let monitorId = doc["id"].getStr()
    if not hasUptimeJob(monitorId):
      let intervalSecs = doc["intervalSecs"].getInt()
      info "Re-enqueueing uptime monitor", monitorId = monitorId
      enqueueUptimeMonitor(monitorId, intervalSecs)

proc startUptimeScheduler*() =
  rebuildStoreIndexes()
  syncUptimeJobsOnStartup()
