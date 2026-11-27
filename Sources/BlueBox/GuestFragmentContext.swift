import Graphite

/// The classic 32-bit CFM InitBlock and its owned locator/name storage.
enum GuestFragmentContext {
    static let address: UInt32 = 0x24000000
    static let containerAddress: UInt32 = address + 4096
    static let specAddress: UInt32 = address + 64
    static let nameAddress: UInt32 = address + 144

    static func bytes(containerLength: Int, application: GuestFile?) -> [UInt8] {
        typealias Coding = GuestAppleEventDescriptors
        // Context, closure and connection IDs identify the sole prepared application fragment.
        var bytes = Coding.word(1) + Coding.word(1) + Coding.word(1)
        if application != nil {
            bytes += Coding.word(1) + Coding.word(specAddress) + Coding.word(0) + Coding.word(UInt32(containerLength))
        } else {
            // kInMem, address/length, inPlace=false with the remaining union bytes reserved.
            bytes += Coding.word(0) + Coding.word(containerAddress) + Coding.word(UInt32(containerLength)) + Coding.word(0)
        }
        bytes += Coding.word(nameAddress) + [UInt8](repeating: 0, count: 16)
        bytes += [UInt8](repeating: 0, count: 64 - bytes.count)
        if let application {
            bytes += GuestFileManager.bytes(FileSpec(volume: GuestFileManager.volume, parent: .root, name: application.name))
        }
        bytes += [UInt8](repeating: 0, count: 144 - bytes.count)
        bytes += application?.name.lengthPrefixed ?? [0]
        return bytes
    }
}
