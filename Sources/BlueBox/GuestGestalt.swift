import Graphite

/// Explicit guest compatibility profile, independent of the host's OS, RAM and instruction set.
enum GuestGestalt {
    static func makeTable() -> Gestalt {
        var table = Gestalt()
        table.replace("sysv", with: .value(0x0900)) // Target compatibility version; API coverage is incremental.
        table.replace("sysa", with: .value(Gestalt.Architecture.powerPC.rawValue))
        table.replace("ram ", with: .value(Int32(GuestHeap.byteCount)))
        table.replace("lram", with: .value(Int32(GuestHeap.byteCount)))
        table.replace("qd  ", with: .value(0)) // Original monochrome QuickDraw, not Color QuickDraw.
        // Optional managers, CPU model/features, and unimplemented selectors remain undefined.
        return table
    }
}
