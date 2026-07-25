# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strformat, strutils, times],
  eth/common,
  eth/keccak/keccak

const
  iterations = 3_000_000
  warmup = 200_000

proc benchGeneric(n: int): (float, uint64) =
  var
    buf {.noinit.}: array[32, byte]
    checksum: uint64
  for i in 0 ..< 32:
    buf[i] = byte(i)

  let start = epochTime()
  for i in 0 ..< n:
    buf[0] = byte(i)
    buf[1] = byte(i shr 8)
    let h = keccak256(buf.toOpenArray(0, 31))
    checksum += uint64(h.data[0]) + uint64(h.data[31])
  (epochTime() - start, checksum)

proc benchSpecialized(n: int): (float, uint64) =
  var
    buf {.noinit.}: array[32, byte]
    checksum: uint64
  for i in 0 ..< 32:
    buf[i] = byte(i)

  let start = epochTime()
  for i in 0 ..< n:
    buf[0] = byte(i)
    buf[1] = byte(i shr 8)
    let h = keccak256_32(buf.toOpenArray(0, 31)).to(Hash32)
    checksum += uint64(h.data[0]) + uint64(h.data[31])
  (epochTime() - start, checksum)

proc report(name: string, elapsed: float, n: int) =
  let
    opsPerSec = n.float / elapsed
    nsPerOp = (elapsed * 1_000_000_000.0) / n.float
  echo "  " & alignLeft(name, 34) & align(fmt"{elapsed:.4f}", 10) & "s " &
    align(fmt"{opsPerSec:.0f}", 12) & " ops/s " & align(fmt"{nsPerOp:.1f}", 8) & " ns/op"

when isMainModule:
  # correctness: both paths must agree for every 32-byte input
  block:
    var buf {.noinit.}: array[32, byte]
    for i in 0 ..< 32:
      buf[i] = byte(i * 7)
    for k in 0 ..< 10_000:
      buf[0] = byte(k)
      buf[1] = byte(k shr 8)
      let
        a = keccak256(buf.toOpenArray(0, 31))
        b = keccak256_32(buf.toOpenArray(0, 31)).to(Hash32)
      doAssert a == b, "mismatch at " & $k
    echo "equivalence: OK (10000 inputs agree)"

  discard benchGeneric(warmup)
  discard benchSpecialized(warmup)

  echo ""
  echo "  keccak256 of 32 bytes, ", iterations, " iterations"
  var
    genTotal, specTotal: float
    c1, c2: uint64
  for round in 0 ..< 3:
    let (ge, gc) = benchGeneric(iterations)
    let (se, sc) = benchSpecialized(iterations)
    genTotal += ge
    specTotal += se
    c1 = gc
    c2 = sc
    report("generic keccak256 (round " & $round & ")", ge, iterations)
    report("keccak256_32     (round " & $round & ")", se, iterations)

  doAssert c1 == c2, "checksum mismatch"
  echo ""
  report("generic keccak256 TOTAL", genTotal, iterations * 3)
  report("keccak256_32 TOTAL", specTotal, iterations * 3)
  echo ""
  echo fmt"  speedup: {genTotal / specTotal:.3f}x  " &
    fmt"({(1.0 - specTotal / genTotal) * 100.0:.1f}% less time)"
