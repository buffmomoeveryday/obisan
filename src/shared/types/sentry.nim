type
  EnvelopeHeader* = object
    event_id: string

  ItemHeader* = object
    `type`: string

  SentryExceptionDetails* = object
    `type`: string
    value: string

  SentryExceptionBlock* = object
    values: seq[SentryExceptionDetails]

  SentryEventPayload* = object
    platform: string
    level: string
    exception: SentryExceptionBlock
