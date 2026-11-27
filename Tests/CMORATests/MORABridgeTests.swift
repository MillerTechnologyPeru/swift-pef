import CMORA
import CMORATestSupport
import Testing

private let bridgeTestDispatch: MORADispatchFunction = { symbol, frame, context in
    guard let frame, let context else { return }
    let count = context.assumingMemoryBound(to: UInt32.self)
    count.pointee += 1
    let first = withUnsafeBytes(of: frame.pointee.gpr) { $0.load(as: UInt32.self) }
    frame.pointee.returnGPR = first + symbol
    frame.pointee.returnGPR2 = 99
    frame.pointee.returnFPR = 2.5
}

@Suite struct MORABridgeTests {
    @Test func invocationLayoutMatchesAssemblyContract() {
        #expect(MemoryLayout<MORAInvocationFrame>.size == 160)
        #expect(MemoryLayout<MORAInvocationFrame>.offset(of: \.fpr) == 32)
        #expect(MemoryLayout<MORAInvocationFrame>.offset(of: \.callerSP) == 136)
        #expect(MemoryLayout<MORAInvocationFrame>.offset(of: \.returnGPR) == 140)
        #expect(MemoryLayout<MORAInvocationFrame>.offset(of: \.returnGPR2) == 144)
        #expect(MemoryLayout<MORAInvocationFrame>.offset(of: \.returnFPR) == 152)
        #expect(MemoryLayout<MORATVector>.size == 8)
    }

    @Test func invalidInvocationIsRejectedBeforeEnteringGuestCode() {
        var frame = MORAInvocationFrame()
        var vector = MORATVector(codeAddress: 3, tocAddress: 0)
        #expect(mora_call(&vector, &frame, bridgeTestDispatch, nil) == MORA_STATUS_INVALID_ARGUMENT)
        #expect(mora_call(nil, &frame, bridgeTestDispatch, nil) == MORA_STATUS_INVALID_ARGUMENT)
    }

    @Test(.enabled(if: mora_import_thunk_address() != 0)) func nativeRegisterArgumentsTOCAndReturns() {
        var toc: UInt32 = 7
        withUnsafePointer(to: &toc) { toc in
            var vector = MORATVector(codeAddress: UInt32(mora_test_leaf_address()),
                                     tocAddress: UInt32(UInt(bitPattern: toc)))
            var frame = MORAInvocationFrame()
            withUnsafeMutableBytes(of: &frame.gpr) { bytes in
                let registers = bytes.bindMemory(to: UInt32.self)
                for index in registers.indices { registers[index] = UInt32(index + 1) }
            }
            withUnsafeMutableBytes(of: &frame.fpr) { bytes in
                let registers = bytes.bindMemory(to: Double.self)
                for index in registers.indices { registers[index] = Double(index + 1) }
            }
            #expect(mora_call(&vector, &frame, bridgeTestDispatch, nil) == MORA_STATUS_SUCCESS)
            #expect(frame.returnGPR == 43)
            #expect(frame.returnGPR2 == (43 ^ 0x1234))
            #expect(frame.returnFPR == 91)
            #expect(frame.callerSP & 15 == 0)
        }
    }

    @Test(.enabled(if: mora_import_thunk_address() != 0)) func nativeImportCallsDispatcherWithSymbolAndContext() {
        var imported = MORATVector(codeAddress: UInt32(mora_import_thunk_address()), tocAddress: 37)
        withUnsafePointer(to: &imported) { imported in
            var vector = MORATVector(codeAddress: UInt32(mora_test_import_address()),
                                     tocAddress: UInt32(UInt(bitPattern: imported)))
            var frame = MORAInvocationFrame()
            withUnsafeMutableBytes(of: &frame.gpr) { $0.storeBytes(of: UInt32(5), as: UInt32.self) }
            var count: UInt32 = 0
            withUnsafeMutablePointer(to: &count) { count in
                #expect(mora_call(&vector, &frame, bridgeTestDispatch, count) == MORA_STATUS_SUCCESS)
            }
            #expect(count == 1)
            #expect(frame.returnGPR == 42)
            #expect(frame.returnGPR2 == 99)
            #expect(frame.returnFPR == 2.5)
        }
    }
    @Test(.enabled(if: mora_import_thunk_address() == 0)) func nonnativeHostsNeverEnterPPCCode() {
        #expect(mora_import_thunk_address() == 0)
        var vector = MORATVector(codeAddress: 0x10000, tocAddress: 0)
        var frame = MORAInvocationFrame()
        frame.returnGPR = 123
        #expect(mora_call(&vector, &frame, bridgeTestDispatch, nil) == MORA_STATUS_UNAVAILABLE)
        #expect(frame.returnGPR == 123)
    }
}
