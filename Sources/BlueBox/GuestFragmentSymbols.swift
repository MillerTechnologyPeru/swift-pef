import Graphite
import PEFKit

/// Owned export metadata for the sole prepared application connection (ID 1).
struct GuestFragmentSymbols {
    struct Symbol {
        let name: [UInt8]
        let address: UInt32
        let symbolClass: UInt8
    }
    let symbols: [Symbol]

    init(symbols: [Symbol]) { self.symbols = symbols }

    init(loader: borrowing PEFLoaderSection, sections: UnsafeBufferPointer<PEFSectionAllocation>,
         imports: UnsafeBufferPointer<UInt32>) throws(PEFError) {
        let addresses = sections.map(\.guestAddress)
        var symbols: [Symbol] = []
        for index in 0..<Int(loader.info.exportedSymbolCount) {
            let symbol = try loader.exportedSymbol(at: index)
            guard let name = loader.name(of: symbol), let symbolClass = symbol.symbolClass else {
                throw .malformedLoaderSection
            }
            if symbol.sectionIndex >= 0 {
                let index = Int(symbol.sectionIndex)
                guard index < sections.count, UInt64(symbol.symbolOffset) <= UInt64(sections[index].bytes.count),
                      UInt64(sections[index].guestAddress) + UInt64(symbol.symbolOffset) <= UInt32.max else {
                    throw .malformedLoaderSection
                }
            }
            let address = try addresses.withUnsafeBufferPointer { (addresses) throws(PEFError) in
                try loader.address(of: symbol, sectionAddresses: addresses, importedAddresses: imports)
            }
            symbols.append(Symbol(name: Array(name), address: address, symbolClass: symbolClass.rawValue))
        }
        self.symbols = symbols
    }

    func validate(connection: UInt32) throws(MacError) {
        guard connection == 1 else { throw MacError(-2801) }
    }

    func find(_ name: [UInt8]) throws(MacError) -> Symbol {
        guard let symbol = symbols.first(where: { $0.name == name }) else { throw MacError(-2802) }
        return symbol
    }
}
