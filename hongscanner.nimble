version       = "0.1.0"
author        = "wintrover"
description   = "Deterministic market event scanner (VS-1 vertical slice)"
license       = "MIT"
srcDir        = "src"
binDir        = "build"
bin           = @["hongscanner"]

requires "nim >= 2.2.10"

task test, "Run the contract test suite (delegates to tools/run_tests.sh)":
  ## NOTE: a failing exec here raises inside nimble's script runner but the
  ## nimble process can still exit 0; the authoritative gate is the script.
  exec "bash tools/run_tests.sh"