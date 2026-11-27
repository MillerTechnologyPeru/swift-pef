import Foundation
import Graphite

/// Initial StopAlert presentation: standard first-stage resources with buttons and static text.
/// Modal input and guest filter callbacks remain pending; presentation never fabricates a button press.
struct GuestAlert {
    struct Item {
        let bounds: Rect
        let isButton: Bool
        let enabled: Bool
        let text: String
    }
    let id: Int16
    let bounds: Rect
    let items: [Item]

    init(id: Int16, resources: ResourceFile, parameters: [PascalString]) throws(MacError) {
        do {
            var alert = BigEndianReader(Data(try resources.bytes(type: "ALRT", id: id)))
            let bounds = try alert.readRect()
            let itemID = try alert.read(Int16.self)
            let stages = try alert.read(UInt16.self)
            guard bounds.width > 0, bounds.height > 0, stages == 0x5555 else { throw MacError.mapRead }
            var list = BigEndianReader(Data(try resources.bytes(type: "DITL", id: itemID)))
            let countMinusOne = try list.read(UInt16.self)
            let count = countMinusOne == 0xFFFF ? 0 : Int(countMinusOne) + 1
            guard count <= list.remaining / 14 else { throw MacError.mapRead }
            var items: [Item] = []
            for _ in 0..<count {
                _ = try list.read(UInt32.self) // Runtime handle slot, unused in a resource.
                let rect = try list.readRect()
                let type = try list.read(UInt8.self)
                let size = Int(try list.read(UInt8.self))
                let bytes = Array(try list.readBytes(size))
                if list.offset & 1 != 0, list.remaining > 0 { _ = try list.read(UInt8.self) }
                let kind = type & 0x7F
                guard kind == 4 || kind == 8, rect.left >= 0, rect.top >= 0,
                      Int(rect.right) <= bounds.width, Int(rect.bottom) <= bounds.height,
                      rect.width > 0, rect.height > 0 else { throw MacError.mapRead }
                var substituted: [UInt8] = []
                var index = 0
                while index < bytes.count {
                    if bytes[index] == 94, index + 1 < bytes.count, (48...51).contains(bytes[index + 1]) {
                        let parameter = Int(bytes[index + 1] - 48)
                        if parameter < parameters.count { substituted += parameters[parameter].bytes }
                        index += 2
                    } else {
                        substituted.append(bytes[index])
                        index += 1
                    }
                }
                items.append(Item(bounds: rect, isButton: kind == 4, enabled: type & 0x80 == 0,
                                  text: MacRoman.decode(substituted)))
            }
            guard items.contains(where: { $0.isButton && $0.enabled }) else { throw MacError.mapRead }
            self.id = id
            self.bounds = bounds
            self.items = items
        } catch let error as MacError {
            throw error
        } catch {
            throw .mapRead
        }
    }

    func draw(on screen: GraphicsDevice, fonts: FontRegistry, font: Int16) {
        let port = Port(pixels: screen.pixels)
        port.perform(.erase, rect: bounds)
        port.perform(.frame, rect: bounds)
        for item in items {
            let rect = item.bounds.offsetBy(dh: bounds.left, dv: bounds.top)
            if item.isButton { port.perform(.frame, roundRect: rect, ovalWidth: 8, ovalHeight: 8) }
            port.clipRegion = Region(rect: rect)
            let text = item.text.replacingOccurrences(of: "\r", with: "\n")
            let layout = TextLayout(text: text,
                                    runs: [TextRun(range: 0..<text.unicodeScalars.count, family: font)],
                                    fonts: fonts, width: Double(max(1, rect.width - 4)))
            layout.draw(in: port, at: Point(v: rect.top, h: Int16(clamping: Int(rect.left) + 2)))
            port.clipRegion = Region(rect: screen.bounds)
        }
    }
}

enum GuestFramebuffer {
    /// Portable RGB snapshot of the configured monochrome screen.
    static func ppm(_ pixels: UnsafeRawBufferPointer) -> [UInt8] {
        var output = Array("P6\n640 480\n255\n".utf8)
        output.reserveCapacity(output.count + 640 * 480 * 3)
        for y in 0..<480 {
            for x in 0..<640 {
                let value: UInt8 = pixels[y * 80 + x / 8] & (0x80 >> (x & 7)) == 0 ? 255 : 0
                output += [value, value, value]
            }
        }
        return output
    }
}
