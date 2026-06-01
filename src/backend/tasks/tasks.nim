import quee
import times
import chronicles
import json

import ../service/metricsService
import ../service/uptimeService
import ../service/uptimeStore
import ../utils/ntfy
import ../utils/webhook

task sendNtfyNotification(topic: string, message: string, title: string):
  queue "notifications"
  postToNtfy(topic, message, title, "high")

task sendWebhookNotification(url: string, eventType: string, payload: string):
  queue "notifications"
  postToWebhook(url, eventType, parseJson(payload))

task writeProjectMetrics(projectDbId: int, payload: string):
  queue "metrics"
  discard saveMetricsPayload(projectDbId, payload)

task checkUptimeMonitor(monitorId: string):
  queue "uptime"
  executeMonitorCheck(monitorId)

proc enqueueNtfy*(topic, message, title: string) =
  discard sendNtfyNotification.enqueue(topic, message, title).run()

proc enqueueWebhook*(url, eventType: string, payload: JsonNode) =
  if url.len == 0:
    return
  discard sendWebhookNotification.enqueue(url, eventType, payload.pretty).run()

proc enqueueProjectMetrics*(projectDbId: int, payload: string) =
  discard writeProjectMetrics.enqueue(projectDbId, payload).run()

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
