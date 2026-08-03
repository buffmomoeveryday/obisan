import std/json

type
  NotificationPriority* = enum
    npLow = "low"
    npNormal = "normal"
    npHigh = "high"

  NotificationMessage* = object
    title*: string
    body*: string
    priority*: NotificationPriority
    eventType*: string
    projectId*: string
    projectName*: string
    data*: JsonNode

  # Base channel type — all channels inherit from this
  NotificationChannel* = ref object of RootObj
    enabled*: bool
    name*: string
