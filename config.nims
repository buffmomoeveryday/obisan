when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
  switch("mm","arc")
  switch("threads", "on")
  switch("ssl","on")

when defined(debug):
  switch("stackTrace", "on")
  switch("lineTrace", "on")
