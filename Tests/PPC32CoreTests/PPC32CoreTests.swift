import Testing
import PPC32Core

/// Tiny assembler for the instruction forms the tests use.
enum Asm {
    static func d(_ op: UInt32, _ rt: Int, _ ra: Int, _ imm: Int) -> UInt32 {
        op << 26 | UInt32(rt) << 21 | UInt32(ra) << 16 | UInt32(truncatingIfNeeded: imm) & 0xFFFF
    }

    static func x(_ rt: Int, _ ra: Int, _ rb: Int, _ xo: UInt32, rc: UInt32 = 0) -> UInt32 {
        31 << 26 | UInt32(rt) << 21 | UInt32(ra) << 16 | UInt32(rb) << 11 | xo << 1 | rc
    }

    static func li(_ rt: Int, _ value: Int) -> UInt32 { d(14, rt, 0, value) }
    static func addi(_ rt: Int, _ ra: Int, _ value: Int) -> UInt32 { d(14, rt, ra, value) }
    static func addic(_ rt: Int, _ ra: Int, _ value: Int) -> UInt32 { d(12, rt, ra, value) }
    static func andiDot(_ ra: Int, _ rs: Int, _ value: Int) -> UInt32 { d(28, rs, ra, value) }
    static func cmpwi(_ field: Int, _ ra: Int, _ value: Int) -> UInt32 {
        11 << 26 | UInt32(field) << 23 | UInt32(ra) << 16 | UInt32(truncatingIfNeeded: value) & 0xFFFF
    }

    static func add(_ rd: Int, _ ra: Int, _ rb: Int) -> UInt32 { x(rd, ra, rb, 266) }
    static func subf(_ rd: Int, _ ra: Int, _ rb: Int) -> UInt32 { x(rd, ra, rb, 40) }
    static func mullw(_ rd: Int, _ ra: Int, _ rb: Int) -> UInt32 { x(rd, ra, rb, 235) }
    static func divw(_ rd: Int, _ ra: Int, _ rb: Int) -> UInt32 { x(rd, ra, rb, 491) }

    static func rlwinm(_ ra: Int, _ rs: Int, _ sh: Int, _ mb: Int, _ me: Int) -> UInt32 {
        21 << 26 | UInt32(rs) << 21 | UInt32(ra) << 16 | UInt32(sh) << 11 | UInt32(mb) << 6 | UInt32(me) << 1
    }

    static func rlwimi(_ ra: Int, _ rs: Int, _ sh: Int, _ mb: Int, _ me: Int) -> UInt32 {
        20 << 26 | UInt32(rs) << 21 | UInt32(ra) << 16 | UInt32(sh) << 11 | UInt32(mb) << 6 | UInt32(me) << 1
    }

    static func bc(_ bo: Int, _ bi: Int, _ displacement: Int) -> UInt32 {
        16 << 26 | UInt32(bo) << 21 | UInt32(bi) << 16 | UInt32(truncatingIfNeeded: displacement) & 0xFFFC
    }

    static func b(_ displacement: Int, link: Bool = false) -> UInt32 {
        18 << 26 | UInt32(truncatingIfNeeded: displacement) & 0x03FF_FFFC | (link ? 1 : 0)
    }

    static let blr: UInt32 = 19 << 26 | 20 << 21 | 16 << 1
    static let bctrl: UInt32 = 19 << 26 | 20 << 21 | 528 << 1 | 1

    static func mtspr(_ spr: Int, _ rs: Int) -> UInt32 {
        31 << 26 | UInt32(rs) << 21 | UInt32(spr & 31) << 16 | UInt32(spr >> 5) << 11 | 467 << 1
    }

    static func mfspr(_ rd: Int, _ spr: Int) -> UInt32 {
        31 << 26 | UInt32(rd) << 21 | UInt32(spr & 31) << 16 | UInt32(spr >> 5) << 11 | 339 << 1
    }

    /// A-form / X-form floating-point instruction (frC in bits 21-25 for `fmul`).
    static func fp(_ op: UInt32, _ frd: Int, _ fra: Int, _ frb: Int, _ xo: UInt32, frc: Int = 0) -> UInt32 {
        op << 26 | UInt32(frd) << 21 | UInt32(fra) << 16 | UInt32(frb) << 11 | UInt32(frc) << 6 | xo << 1
    }
}

/// Copyable view of the machine after a run, so `#expect` never has to capture the noncopyable state.
struct Snapshot {
    var gpr: [UInt32]
    var fpr: [Double]
    var pc: UInt32
    var lr: UInt32
    var ctr: UInt32
    var cr: UInt32
    var xer: UInt32
    var result: PPC32StepResult
    var memory: [UInt8]

    func word(at address: Int) -> UInt32 {
        UInt32(memory[address]) << 24 | UInt32(memory[address + 1]) << 16
            | UInt32(memory[address + 2]) << 8 | UInt32(memory[address + 3])
    }

    func doubleBits(at address: Int) -> UInt64 {
        UInt64(word(at: address)) << 32 | UInt64(word(at: address + 4))
    }
}

let entry: UInt32 = 0x1000

/// Assembles `program` at `entry`, runs it with LR set to the host-return sentinel, and snapshots the result.
func run(
    _ program: [UInt32],
    maxInstructions: Int = 10_000,
    memorySetup: (UnsafeMutableRawPointer) -> Void = { _ in },
    setup: (inout PPC32State) -> Void = { _ in }
) -> Snapshot {
    let size = 0x10000
    let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { memory.deallocate() }
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    memorySetup(memory)

    var state = PPC32State(memoryBase: memory)
    for (index, word) in program.enumerated() {
        state.writeUInt32(word, at: entry + UInt32(index * 4))
    }
    state.pc = entry
    state.lr = PPC32State.returnSentinel
    setup(&state)

    let result = state.run(maxInstructions: maxInstructions)
    var gpr: [UInt32] = []
    var fpr: [Double] = []
    for index in 0..<32 {
        gpr.append(state.gpr[index])
        fpr.append(state.fpr[index])
    }
    let bytes = Array(UnsafeRawBufferPointer(start: memory, count: size))
    return Snapshot(
        gpr: gpr, fpr: fpr, pc: state.pc, lr: state.lr, ctr: state.ctr,
        cr: state.cr, xer: state.xer, result: result, memory: bytes
    )
}

@Suite struct IntegerTests {
    @Test func arithmetic() {
        let s = run([
            Asm.li(3, 5), Asm.li(4, 7),
            Asm.add(5, 3, 4), Asm.subf(6, 3, 4),
            Asm.mullw(7, 3, 4), Asm.divw(8, 7, 3),
            Asm.blr,
        ])
        #expect(s.result == .returnToHost)
        #expect(s.gpr[5] == 12)
        #expect(s.gpr[6] == 2) // subf rD = rB - rA
        #expect(s.gpr[7] == 35)
        #expect(s.gpr[8] == 7)
    }

    @Test func rotateAndMask() {
        let s = run([
            Asm.rlwinm(4, 3, 8, 24, 31), // extract the byte rotated into the low position
            Asm.rlwinm(5, 3, 0, 28, 3), // wrapping mask 0xF000000F
            Asm.rlwinm(6, 3, 16, 0, 31),
            Asm.rlwimi(7, 3, 0, 8, 15),
            Asm.blr,
        ]) { state in
            state.gpr[3] = 0xAABB_CCDD
            state.gpr[7] = 0xFFFF_FFFF
        }
        #expect(s.gpr[4] == 0xAA)
        #expect(s.gpr[5] == 0xA000_000D)
        #expect(s.gpr[6] == 0xCCDD_AABB)
        #expect(s.gpr[7] == 0xFFBB_FFFF)
    }

    @Test func carryChain() {
        let s = run([
            Asm.li(3, -1),
            Asm.addic(4, 3, 1), // 0xFFFFFFFF + 1 carries out
            Asm.x(5, 6, 0, 202), // addze r5, r6 adds the carry
            Asm.blr,
        ])
        #expect(s.gpr[4] == 0)
        #expect(s.gpr[5] == 1)
        #expect(s.xer & 0x2000_0000 != 0)
    }

    @Test func shiftRightAlgebraicSetsCarry() {
        let s = run([
            Asm.li(7, -3),
            Asm.x(7, 8, 1, 824), // srawi r8, r7, 1
            Asm.blr,
        ])
        #expect(s.gpr[8] == 0xFFFF_FFFE)
        #expect(s.xer & 0x2000_0000 != 0)
    }

    @Test func recordFormSetsCR0() {
        let s = run([
            Asm.li(3, 0xF0),
            Asm.andiDot(4, 3, 0x0F), // 0xF0 & 0x0F == 0 -> EQ
            Asm.blr,
        ])
        #expect(s.cr >> 28 == 0x2)
    }

    @Test func countLeadingZeros() {
        let s = run([Asm.x(3, 4, 0, 26), Asm.blr]) { $0.gpr[3] = 0x0001_0000 }
        #expect(s.gpr[4] == 15)
    }
}

@Suite struct BranchTests {
    @Test func countedLoop() {
        let s = run([
            Asm.li(3, 0), Asm.li(4, 10), Asm.mtspr(9, 4),
            Asm.addi(5, 5, 1), // loop:
            Asm.add(3, 3, 5),
            Asm.bc(16, 0, -8), // bdnz loop
            Asm.blr,
        ])
        #expect(s.result == .returnToHost)
        #expect(s.gpr[3] == 55)
        #expect(s.ctr == 0)
    }

    @Test func callAndReturn() {
        let s = run([
            Asm.mfspr(31, 8), // save the host return address
            Asm.b(12, link: true), // bl +12
            Asm.mtspr(8, 31),
            Asm.blr,
            Asm.li(3, 42), // callee
            Asm.blr,
        ])
        #expect(s.result == .returnToHost)
        #expect(s.gpr[3] == 42)
    }

    @Test func conditionalBranch() {
        let s = run([
            Asm.li(3, 5),
            Asm.cmpwi(0, 3, 5),
            Asm.bc(12, 2, 12), // beq +12, skipping the next two instructions
            Asm.li(4, 1),
            Asm.li(4, 2),
            Asm.li(5, 3),
            Asm.blr,
        ])
        #expect(s.gpr[4] == 0)
        #expect(s.gpr[5] == 3)
    }

    @Test func compareLessThan() {
        let s = run([Asm.li(3, 5), Asm.cmpwi(0, 3, 7), Asm.blr])
        #expect(s.cr >> 28 == 0x8)
    }

    @Test func illegalInstructionStaysOnInstruction() {
        let s = run([0])
        #expect(s.result == .illegalInstruction)
        #expect(s.pc == entry)
    }

    @Test func importTrapRoundTrip() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 0x10000, alignment: 16)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 0x10000)

        var state = PPC32State(memoryBase: memory)
        let program = [Asm.mfspr(31, 8), Asm.bctrl, Asm.mtspr(8, 31), Asm.blr]
        for (index, word) in program.enumerated() {
            state.writeUInt32(word, at: entry + UInt32(index * 4))
        }
        state.pc = entry
        state.lr = PPC32State.returnSentinel
        state.ctr = PPC32State.importTrapBase + 2 * 4

        let first = state.run(maxInstructions: 10)
        let symbol = state.importSymbolIndex
        let linkAfterCall = state.lr

        state.gpr[3] = 99 // the host writes the import's return value
        state.returnFromImportTrap()
        let second = state.run(maxInstructions: 10)
        let returned = state.gpr[3]

        #expect(first == .cfmImportTrap)
        #expect(symbol == 2)
        #expect(linkAfterCall == entry + 8)
        #expect(second == .returnToHost)
        #expect(returned == 99)
    }
}

@Suite struct MemoryTests {
    @Test func bigEndianLoadsAndStores() {
        let s = run([
            Asm.li(3, 0x1234),
            Asm.d(36, 3, 0, 0x2000), // stw
            Asm.d(32, 4, 0, 0x2000), // lwz
            Asm.d(40, 5, 0, 0x2002), // lhz
            Asm.d(34, 6, 0, 0x2003), // lbz
            Asm.li(7, -2),
            Asm.d(44, 7, 0, 0x2010), // sth
            Asm.d(42, 8, 0, 0x2010), // lha sign-extends
            Asm.blr,
        ])
        #expect(Array(s.memory[0x2000..<0x2004]) == [0x00, 0x00, 0x12, 0x34])
        #expect(s.gpr[4] == 0x1234)
        #expect(s.gpr[5] == 0x1234)
        #expect(s.gpr[6] == 0x34)
        #expect(s.gpr[8] == 0xFFFF_FFFE)
    }

    @Test func storeWithUpdate() {
        let s = run([
            Asm.li(3, 0x1234),
            Asm.li(1, 0x7000),
            Asm.d(37, 3, 1, -16), // stwu r3, -16(r1)
            Asm.blr,
        ])
        #expect(s.gpr[1] == 0x6FF0)
        #expect(s.word(at: 0x6FF0) == 0x1234)
    }

    @Test func loadAndStoreMultiple() {
        let s = run([
            Asm.d(47, 29, 0, 0x3000), // stmw r29, 0x3000(0)
            Asm.li(29, 0), Asm.li(30, 0), Asm.li(31, 0),
            Asm.d(46, 29, 0, 0x3000), // lmw r29, 0x3000(0)
            Asm.blr,
        ]) { state in
            state.gpr[29] = 1
            state.gpr[30] = 2
            state.gpr[31] = 3
        }
        #expect(s.word(at: 0x3000) == 1)
        #expect(s.word(at: 0x3008) == 3)
        #expect(s.gpr[29] == 1)
        #expect(s.gpr[30] == 2)
        #expect(s.gpr[31] == 3)
    }

    @Test func byteReversedStore() {
        let s = run([Asm.x(3, 0, 4, 662), Asm.blr]) { // stwbrx r3, 0, r4
            $0.gpr[3] = 0x1122_3344
            $0.gpr[4] = 0x2000
        }
        #expect(Array(s.memory[0x2000..<0x2004]) == [0x44, 0x33, 0x22, 0x11])
    }
}

@Suite struct FloatTests {
    private func store(_ value: Double, at address: Int, in memory: UnsafeMutableRawPointer) {
        memory.storeBytes(of: value.bitPattern.bigEndian, toByteOffset: address, as: UInt64.self)
    }

    @Test func doublePrecisionArithmetic() {
        let s = run([
            Asm.d(50, 1, 0, 0x2000), // lfd f1
            Asm.d(50, 2, 0, 0x2008), // lfd f2
            Asm.fp(63, 3, 1, 2, 21), // fadd f3, f1, f2
            Asm.fp(63, 4, 1, 0, 25, frc: 2), // fmul f4, f1, f2
            Asm.d(54, 3, 0, 0x2010), // stfd f3
            Asm.fp(63, 0, 1, 2, 0), // fcmpu cr0, f1, f2
            Asm.fp(63, 6, 0, 4, 15), // fctiwz f6, f4
            Asm.blr,
        ], memorySetup: { memory in
            store(1.5, at: 0x2000, in: memory)
            store(2.25, at: 0x2008, in: memory)
        })
        #expect(s.fpr[3] == 3.75)
        #expect(s.fpr[4] == 3.375)
        #expect(s.doubleBits(at: 0x2010) == (3.75).bitPattern)
        #expect(s.cr >> 28 == 0x8) // 1.5 < 2.25
        #expect(UInt32(truncatingIfNeeded: s.fpr[6].bitPattern) == 3)
    }

    @Test func singlePrecisionRoundsToFloat() {
        let s = run([
            Asm.fp(59, 3, 1, 2, 21), // fadds f3, f1, f2
            Asm.blr,
        ]) { state in
            state.fpr[1] = 1.0
            state.fpr[2] = 1e-10 // lost when rounded to single precision
        }
        #expect(s.fpr[3] == 1.0)
    }
}
