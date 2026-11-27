import Graphite

/// Initial monochrome Menu Manager state. Resource menus and tracking are not yet implemented.
/// https://dev.os9.ca/techpubs/mac/Toolbox/Toolbox-114.html
final class HeadlessMenuManager {
    static let barHeight: Int16 = 20
    private let port: Port
    private(set) var menuIDs: [Int16] = []

    init(screen: GraphicsDevice) {
        port = Port(pixels: screen.pixels)
        port.device = screen
        drawMenuBar()
    }

    func clearMenuBar() {
        menuIDs.removeAll()
    }

    /// Draw the initial empty Roman-script menu bar into the shared guest framebuffer.
    func drawMenuBar() {
        let bounds = port.portRect
        let bottom = min(bounds.bottom, bounds.top + Self.barHeight)
        port.perform(.erase, rect: Rect(top: bounds.top, left: bounds.left,
                                       bottom: bottom, right: bounds.right))
        port.perform(.paint, rect: Rect(top: bottom - 1, left: bounds.left,
                                       bottom: bottom, right: bounds.right))
    }
}
