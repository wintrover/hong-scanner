version       = "0.1.0"
author        = "wintrover"
description   = "Deterministic market event scanner (VS-1 vertical slice)"
license       = "MIT"
srcDir        = "src"
binDir        = "build"
bin           = @["hongscanner"]

requires "nim >= 2.2.10"

task test, "Run the contract test suite":
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_all.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_engine_contract.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_provenance_contract.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_input_contract.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_bars_contract.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_rest_failure_contract.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_vendor_input.nim"
  exec "nim c -r --hints:off --warnings:off --path:src tests/test_recorder_contract.nim"
  exec "bash tests/test_cli_contract.sh"
  exec "bash tests/test_build_contract.sh"
  exec "bash tests/test_install_attested.sh"
  exec "python3 tests/test_calendar_source.py"