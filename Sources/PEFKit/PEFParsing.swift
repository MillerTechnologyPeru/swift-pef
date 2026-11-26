import BinaryParsing

// Thin adapters that surface BinaryParsing's `ParsingError` as `PEFError.parsing`, so PEF parsers
// can use a single typed-throws error. All PEF fields are big-endian.
extension ParserSpan {
    mutating func readUInt8() throws(PEFError) -> UInt8 {
        do throws(ParsingError) { return try UInt8(parsing: &self) } catch { throw .parsing(error) }
    }

    mutating func readUInt16() throws(PEFError) -> UInt16 {
        do throws(ParsingError) { return try UInt16(parsingBigEndian: &self) } catch { throw .parsing(error) }
    }

    mutating func readInt16() throws(PEFError) -> Int16 {
        do throws(ParsingError) { return try Int16(parsingBigEndian: &self) } catch { throw .parsing(error) }
    }

    mutating func readUInt32() throws(PEFError) -> UInt32 {
        do throws(ParsingError) { return try UInt32(parsingBigEndian: &self) } catch { throw .parsing(error) }
    }

    mutating func readInt32() throws(PEFError) -> Int32 {
        do throws(ParsingError) { return try Int32(parsingBigEndian: &self) } catch { throw .parsing(error) }
    }

    /// Moves to an absolute offset within the underlying bytes.
    mutating func seek(absoluteOffset offset: UInt64) throws(PEFError) {
        guard offset <= UInt64(Int.max) else { throw .malformedLoaderSection }
        do throws(ParsingError) {
            try seek(toAbsoluteOffset: Int(offset))
        } catch {
            throw .parsing(error)
        }
    }
}
