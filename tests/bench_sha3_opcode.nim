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
  stint,
  ./macro_assembler,
  ../execution_chain/db/ledger,
  ../execution_chain/evm/state,
  ../execution_chain/evm/types,
  ../execution_chain/evm/interpreter/op_codes,
  ../execution_chain/transaction/call_types,
  ../execution_chain/transaction/call_common

const
  iterations = 300_000
  rounds = 3

proc buildLoopCode(n: int, withSha3: bool): seq[byte] =
  var c: seq[byte] = @[]

  c.add byte(Op.Push32)
  for i in 0 ..< 32:
    c.add byte(i + 1)
  c.add byte(Op.Push1)
  c.add 0x00'u8
  c.add byte(Op.Mstore)

  c.add byte(Op.Push4)
  c.add byte(n shr 24)
  c.add byte(n shr 16)
  c.add byte(n shr 8)
  c.add byte(n)

  let loopStart = c.len
  c.add byte(Op.JumpDest)

  c.add byte(Op.Push1)
  c.add 0x20'u8
  c.add byte(Op.Push1)
  c.add 0x00'u8
  if withSha3:
    c.add byte(Op.Sha3)
    c.add byte(Op.Pop)
  else:
    c.add byte(Op.Pop)
    c.add byte(Op.Pop)

  c.add byte(Op.Push1)
  c.add 0x01'u8
  c.add byte(Op.Swap1)
  c.add byte(Op.Sub)
  c.add byte(Op.Dup1)
  c.add byte(Op.Push2)
  c.add byte(loopStart shr 8)
  c.add byte(loopStart)
  c.add byte(Op.JumpI)
  c.add byte(Op.Stop)
  c

proc runCode(code: seq[byte]): (float, GasInt, string) =
  let vmState = initVMEnv("Cancun")
  vmState.mutateLedger:
    ledger.setCode(codeAddress, code)
    ledger.setBalance(codeAddress, 1_000_000.u256)

  let params = CallParams(
    vmState: vmState,
    gasPrice: 0.GasInt,
    gasLimit: 400_000_000.GasInt,
    sender: default(Address),
    to: codeAddress,
    isCreate: false,
    value: 0.u256,
    input: @[],
  )

  let start = epochTime()
  let res = runComputation(params, CallResult)
  let elapsed = epochTime() - start
  (elapsed, res.gasUsed, res.error)

proc report(name: string, elapsed: float, n: int) =
  let nsPerOp = (elapsed * 1_000_000_000.0) / n.float
  echo "  " & alignLeft(name, 30) & align(fmt"{elapsed:.4f}", 9) & "s " &
    align(fmt"{nsPerOp:.1f}", 9) & " ns/iter"

when isMainModule:
  let
    sha3Code = buildLoopCode(iterations, true)
    baseCode = buildLoopCode(iterations, false)

  echo "  code sizes: sha3=", sha3Code.len, " base=", baseCode.len
  echo "  iterations: ", iterations
  echo ""

  block:
    let (_, gas, err) = runCode(sha3Code)
    echo "  warmup sha3 : gasUsed=", gas, " error=\"", err, "\""
    doAssert err.len == 0, "sha3 loop failed: " & err
  block:
    let (_, gas, err) = runCode(baseCode)
    echo "  warmup base : gasUsed=", gas, " error=\"", err, "\""
    doAssert err.len == 0, "base loop failed: " & err
  echo ""

  var sha3Total, baseTotal: float
  for r in 0 ..< rounds:
    let (se, _, _) = runCode(sha3Code)
    let (be, _, _) = runCode(baseCode)
    sha3Total += se
    baseTotal += be
    report("loop WITH sha3 (r" & $r & ")", se, iterations)
    report("loop WITHOUT sha3 (r" & $r & ")", be, iterations)

  echo ""
  let
    n = iterations * rounds
    sha3Ns = (sha3Total * 1e9) / n.float
    baseNs = (baseTotal * 1e9) / n.float
    opNs = sha3Ns - baseNs
  report("TOTAL with sha3", sha3Total, n)
  report("TOTAL without sha3", baseTotal, n)
  echo ""
  echo fmt"  isolated SHA3 opcode cost: {opNs:.1f} ns/op"
  echo fmt"  (loop scaffolding overhead: {baseNs:.1f} ns/iter)"
