version       = "0.1.0"
author        = "wintrover"
description   = "Deterministic market event scanner (VS-1 vertical slice)"
license       = "MIT"
srcDir        = "src"
bin           = @["hongscanner"]

requires "nim >= 2.2.10"

task test, "Run the contract test suite":
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_all.nim"