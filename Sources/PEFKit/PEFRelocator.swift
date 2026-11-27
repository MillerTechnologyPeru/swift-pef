/// Executes Apple's PEF relocation bytecode without allocating or depending on host addresses.
public enum PEFRelocator {
    /// Section adjustments are instantiated addresses minus their header default addresses.
    /// All buffers must remain valid and must not overlap. Errors can leave partial fixups;
    /// discard the destination section on failure. The budget bounds hostile repeat streams.
    public static func apply(
        instructions: UnsafeRawBufferPointer,
        to output: UnsafeMutableRawBufferPointer,
        sectionAdjustments: UnsafeBufferPointer<UInt32>,
        importedAddresses: UnsafeBufferPointer<UInt32>,
        operationLimit: Int = 1_000_000
    ) throws(PEFError) {
        guard instructions.count % 2 == 0 else { throw .invalidRelocation(0) }
        var machine = Machine(
            instructions: instructions, output: output,
            sections: sectionAdjustments, imports: importedAddresses,
            sectionC: sectionAdjustments.isEmpty ? 0 : sectionAdjustments[0],
            sectionD: sectionAdjustments.count < 2 ? 0 : sectionAdjustments[1],
            remaining: max(0, operationLimit)
        )
        try machine.execute(from: 0, to: instructions.count, repeating: false)
    }

    private struct Machine {
        let instructions: UnsafeRawBufferPointer
        let output: UnsafeMutableRawBufferPointer
        let sections: UnsafeBufferPointer<UInt32>
        let imports: UnsafeBufferPointer<UInt32>
        var sectionC: UInt32
        var sectionD: UInt32
        var remaining: Int
        var position = 0
        var importIndex = 0

        mutating func spend() throws(PEFError) {
            guard remaining > 0 else { throw .relocationLimitExceeded }
            remaining -= 1
        }

        func word(at offset: Int) -> UInt16 {
            UInt16(instructions[offset]) << 8 | UInt16(instructions[offset + 1])
        }

        func section(_ index: Int) throws(PEFError) -> UInt32 {
            guard index < sections.count else { throw .invalidRelocation(0) }
            return sections[index]
        }

        mutating func move(to offset: Int) throws(PEFError) {
            guard offset >= 0, offset <= output.count else {
                throw .relocationOutOfBounds(offset: offset)
            }
            position = offset
        }

        mutating func advance(_ count: Int) throws(PEFError) {
            guard count <= output.count - position else {
                throw .relocationOutOfBounds(offset: position)
            }
            position += count
        }

        mutating func add(_ value: UInt32) throws(PEFError) {
            try spend()
            guard output.count >= 4, position <= output.count - 4 else {
                throw .relocationOutOfBounds(offset: position)
            }
            let old = UInt32(bigEndian: output.loadUnaligned(fromByteOffset: position, as: UInt32.self))
            output.storeBytes(of: (old &+ value).bigEndian, toByteOffset: position, as: UInt32.self)
            position += 4
        }

        mutating func addImport(_ index: Int) throws(PEFError) {
            guard index < imports.count else { throw .invalidRelocation(0) }
            try add(imports[index])
            importIndex = index + 1
        }

        // Repeat blocks must start at instruction boundaries, never at a long operand.
        mutating func isBoundary(_ offset: Int) throws(PEFError) -> Bool {
            var cursor = 0
            while cursor < offset {
                try spend()
                let opcode = word(at: cursor)
                cursor += opcode & 0xFC00 == 0xA000 || opcode & 0xFC00 == 0xA400
                    || opcode & 0xFC00 == 0xB000 || opcode & 0xFC00 == 0xB400 ? 4 : 2
            }
            return cursor == offset
        }

        mutating func execute(from start: Int, to end: Int, repeating: Bool) throws(PEFError) {
            var cursor = start
            while cursor < end {
                try spend()
                let instructionStart = cursor
                let op = word(at: cursor)
                cursor += 2
                let group = op >> 9
                if op & 0xC000 == 0 {
                    try advance(Int((op >> 6) & 0xFF) * 4)
                    for _ in 0..<Int(op & 0x3F) { try add(sectionD) }
                } else if (0x20...0x25).contains(group) {
                    for _ in 0...Int(op & 0x1FF) {
                        switch group {
                        case 0x20: try add(sectionC)
                        case 0x21: try add(sectionD)
                        case 0x22, 0x23:
                            try add(sectionC)
                            try add(sectionD)
                            if group == 0x22 { try advance(4) }
                        case 0x24:
                            try add(sectionD)
                            try advance(4)
                        default: try addImport(importIndex)
                        }
                    }
                } else if (0x30...0x33).contains(group) {
                    let index = Int(op & 0x1FF)
                    switch group {
                    case 0x30: try addImport(index)
                    case 0x31: sectionC = try section(index)
                    case 0x32: sectionD = try section(index)
                    default: try add(section(index))
                    }
                } else if op & 0xF000 == 0x8000 {
                    try advance(Int(op & 0xFFF) + 1)
                } else if op & 0xF000 == 0x9000 || op & 0xFC00 == 0xB000 {
                    guard !repeating else { throw .invalidRelocation(op) }
                    let blocks: Int
                    let count: Int
                    if op & 0xF000 == 0x9000 {
                        blocks = Int((op >> 8) & 0xF) + 1
                        count = Int(op & 0xFF) + 1
                    } else {
                        guard cursor + 2 <= end else { throw .invalidRelocation(op) }
                        blocks = Int((op >> 6) & 0xF) + 1
                        count = Int(op & 0x3F) << 16 | Int(word(at: cursor))
                        cursor += 2
                    }
                    let blockStart = instructionStart - blocks * 2
                    guard blockStart >= start, try isBoundary(blockStart) else {
                        throw .invalidRelocation(op)
                    }
                    for _ in 0..<count {
                        try spend()
                        try execute(from: blockStart, to: instructionStart, repeating: true)
                    }
                } else if op & 0xFC00 == 0xA000 || op & 0xFC00 == 0xA400
                            || op & 0xFC00 == 0xB400 {
                    guard cursor + 2 <= end else { throw .invalidRelocation(op) }
                    let low = Int(word(at: cursor))
                    cursor += 2
                    if op & 0xFC00 == 0xA000 {
                        try move(to: Int(op & 0x3FF) << 16 | low)
                    } else if op & 0xFC00 == 0xA400 {
                        try addImport(Int(op & 0x3FF) << 16 | low)
                    } else {
                        let value = try section(Int(op & 0x3F) << 16 | low)
                        switch (op >> 6) & 0xF {
                        case 0: try add(value)
                        case 1: sectionC = value
                        case 2: sectionD = value
                        default: throw .invalidRelocation(op)
                        }
                    }
                } else {
                    throw .invalidRelocation(op)
                }
            }
        }
    }
}
