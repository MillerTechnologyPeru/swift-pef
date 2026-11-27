/// Caller-owned storage for one instantiated section, in container section order.
public struct PEFSectionAllocation {
    public let guestAddress: UInt32
    public let bytes: UnsafeMutableRawBufferPointer

    public init(guestAddress: UInt32, bytes: UnsafeMutableRawBufferPointer) {
        self.guestAddress = guestAddress
        self.bytes = bytes
    }
}

/// Guest addresses of entry records. Preparation never executes guest code.
public struct PEFEntryPoints: Sendable {
    public let main: UInt32?
    public let initialize: UInt32?
    public let terminate: UInt32?
}

extension PEFLoaderSection {
    /// Resolves libraries once, then their symbols into caller-owned storage.
    /// Library IDs are opaque values supplied by the host. Missing weak libraries and symbols
    /// resolve to zero. A present weak library must still provide its required symbols.
    /// Names borrow the loader bytes; output must not overlap them.
    /// On failure, discard the partially written output.
    public func resolveImports(
        into addresses: UnsafeMutableBufferPointer<UInt32>,
        resolveLibrary: (PEFImportedLibrary, UnsafeRawBufferPointer) throws(PEFError) -> UInt32?,
        resolveSymbol: (UInt32, PEFImportedSymbol, UnsafeRawBufferPointer) throws(PEFError) -> UInt32?
    ) throws(PEFError) {
        let count = Int(info.totalImportedSymbolCount)
        guard addresses.count >= count else { throw .outputBufferTooSmall }
        // Temporarily reuse the output to check complete, disjoint library ownership.
        for index in 0..<count { addresses[index] = UInt32.max }
        for libraryIndex in 0..<Int(info.importedLibraryCount) {
            let library = try importedLibrary(at: libraryIndex)
            let start = Int(library.firstImportedSymbol)
            let end = start + Int(library.importedSymbolCount)
            for index in start..<end {
                guard addresses[index] == UInt32.max else { throw .malformedLoaderSection }
                addresses[index] = UInt32(libraryIndex)
            }
        }
        for index in 0..<count {
            guard addresses[index] != UInt32.max else { throw .malformedLoaderSection }
        }
        for libraryIndex in 0..<Int(info.importedLibraryCount) {
            let library = try importedLibrary(at: libraryIndex)
            guard let libraryName = name(atOffset: library.nameOffset) else { throw .malformedLoaderSection }
            let identifier = try resolveLibrary(library, libraryName)
            let start = Int(library.firstImportedSymbol)
            let end = start + Int(library.importedSymbolCount)
            guard let identifier else {
                guard library.isWeak else {
                    throw .unresolvedSymbol(hash: CFMHash.computeHashWord(libraryName.bindMemory(to: UInt8.self)))
                }
                for index in start..<end { addresses[index] = 0 }
                continue
            }
            for index in start..<end {
                let symbol = try importedSymbol(at: index)
                guard let symbolName = name(atOffset: symbol.nameOffset) else { throw .malformedLoaderSection }
                if let address = try resolveSymbol(identifier, symbol, symbolName) {
                    addresses[index] = address
                } else if symbol.isWeak {
                    addresses[index] = 0
                } else {
                    throw .unresolvedSymbol(hash: CFMHash.computeHashWord(symbolName.bindMemory(to: UInt8.self)))
                }
            }
        }
    }
}

extension PEFContainer {
    /// Unpacks and relocates instantiated sections using resolved guest import addresses.
    ///
    /// All buffers must remain alive and must not overlap each other or the source container.
    /// Only each section's totalLength is written; scratch receives address-minus-default
    /// adjustments and needs one word per section. Guest ranges must be disjoint and aligned.
    /// On failure, discard partial output and retry from the original container.
    /// The operation limit applies separately to each relocation stream.
    public func prepare(
        sections: UnsafeBufferPointer<PEFSectionAllocation>,
        importedAddresses: UnsafeBufferPointer<UInt32>,
        relocationScratch: UnsafeMutableBufferPointer<UInt32>,
        operationLimit: Int = 1_000_000
    ) throws(PEFError) -> PEFEntryPoints {
        let count = Int(header.instSectionCount)
        guard sections.count == count else { throw .invalidSectionLayout }
        guard relocationScratch.count >= count else { throw .outputBufferTooSmall }
        // Validate all allocations and loader references before writing initialized bytes.
        for index in 0..<count {
            let section = try section(at: index)
            let allocation = sections[index]
            let start = UInt64(allocation.guestAddress)
            let end = start + UInt64(section.totalLength)
            guard UInt64(allocation.bytes.count) >= UInt64(section.totalLength),
                  end <= UInt64(1) << 32,
                  start % (UInt64(1) << section.alignment) == 0 else {
                throw .invalidSectionLayout
            }
            for previous in 0..<index {
                let other = sections[previous]
                let otherLength = UInt64(try self.section(at: previous).totalLength)
                let otherStart = UInt64(other.guestAddress)
                guard section.totalLength == 0 || otherLength == 0
                    || end <= otherStart || otherStart + otherLength <= start else {
                    throw .invalidSectionLayout
                }
            }
        }
        guard let loader = try loaderSection() else {
            try unpackAll(sections: sections, scratch: relocationScratch)
            return PEFEntryPoints(main: nil, initialize: nil, terminate: nil)
        }
        guard UInt64(importedAddresses.count) >= UInt64(loader.info.totalImportedSymbolCount) else {
            throw .outputBufferTooSmall
        }
        try unpackAll(sections: sections, scratch: relocationScratch)
        let adjustments = UnsafeBufferPointer(rebasing: relocationScratch[0..<count])
        for index in 0..<Int(loader.info.relocSectionCount) {
            let relocation = try loader.relocationHeader(at: index)
            let target = Int(relocation.sectionIndex)
            let length = Int(try section(at: target).totalLength)
            let output = UnsafeMutableRawBufferPointer(rebasing: sections[target].bytes[0..<length])
            try PEFRelocator.apply(
                instructions: loader.relocationInstructions(for: relocation),
                to: output, sectionAdjustments: adjustments,
                importedAddresses: importedAddresses, operationLimit: operationLimit
            )
        }
        return PEFEntryPoints(
            main: Self.entryAddress(section: loader.info.mainSection, offset: loader.info.mainOffset, sections: sections),
            initialize: Self.entryAddress(section: loader.info.initSection, offset: loader.info.initOffset, sections: sections),
            terminate: Self.entryAddress(section: loader.info.termSection, offset: loader.info.termOffset, sections: sections)
        )
    }

    private func unpackAll(
        sections: UnsafeBufferPointer<PEFSectionAllocation>,
        scratch: UnsafeMutableBufferPointer<UInt32>
    ) throws(PEFError) {
        for index in 0..<sections.count {
            scratch[index] = sections[index].guestAddress &- (try section(at: index)).defaultAddress
            try unpackSection(at: index, into: sections[index].bytes)
        }
    }

    private static func entryAddress(
        section: Int32, offset: UInt32, sections: UnsafeBufferPointer<PEFSectionAllocation>
    ) -> UInt32? {
        section == -1 ? nil : sections[Int(section)].guestAddress &+ offset
    }
}
