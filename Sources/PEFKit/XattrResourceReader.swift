import CResourceIO

/// Reads native macOS or Linux user.com.apple.ResourceFork attributes into caller-owned storage.
/// Size queries and reads are separate: retry after a size-change error if another process edits it.
public enum XattrResourceReader {
    public static func byteCount(path: UnsafePointer<CChar>) throws(PEFError) -> Int {
        var error: Int32 = 0
        let result = pef_read_resource_xattr(path, nil, 0, &error)
        guard result >= 0 else { throw .resourceIOFailed(error) }
        return result
    }

    public static func read(
        path: UnsafePointer<CChar>,
        into output: UnsafeMutableRawBufferPointer
    ) throws(PEFError) -> Int {
        // A zero-size getxattr is a size query, so check the returned count as well.
        var error: Int32 = 0
        let result = pef_read_resource_xattr(path, output.baseAddress, output.count, &error)
        guard result >= 0 else { throw .resourceIOFailed(error) }
        guard result <= output.count else { throw .outputBufferTooSmall }
        return result
    }
}
