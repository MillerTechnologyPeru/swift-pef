import Graphite

/// Dialog defaults and copied substitution strings; guest callbacks are retained as guest addresses.
/// https://dev.os9.ca/techpubs/mac/Toolbox/Toolbox-391.html
struct DialogManagerState {
    let resumeProcedure: UInt32
    var font: Int16 = 0
    var parameterText = [PascalString](repeating: PascalString(), count: 4)
}
