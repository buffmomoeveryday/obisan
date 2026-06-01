import json, quickjwt, strutils

{.passL: "-lcrypto".}

const jwtAlgorithm = "HS256"

type JwtError* = object of CatchableError

proc encodeJwt*(payload: JsonNode, secret: string): string =
  result = quickjwt.sign(
    %* {"alg": jwtAlgorithm, "typ": "JWT"},
    payload,
    secret
  )

proc decodeJwt*(token, secret: string): JsonNode =
  if token.split('.').len != 3:
    raise newException(JwtError, "Invalid token")

  try:
    quickjwt.verifyEx(token, secret, @[jwtAlgorithm])
    result = quickjwt.claim(token)
  except Exception as e:
    let msg = $e.msg
    raise newException(JwtError, msg)
