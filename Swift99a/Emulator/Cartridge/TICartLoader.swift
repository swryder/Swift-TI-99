// Swift 99/a
// TiCart file format loader
//
// TiCart format (descripbed below is used by the Windows
// "Win994a" emulator by Cory Burr (BurrSoft).
//
// ============================================================================
// TiCart File Format Specification
// ============================================================================
//
// A .TiCart file is a compound container holding cartridge ROM/GROM data,
// a text description, and an emulator state snapshot.
//
// LAYER 1 — File Header (12 bytes)
// ---------------------------------
//   Offset  Size  Content
//   0       12    Magic string "Win994aCart\0" (ASCII + null terminator)
//           Hex:  57 69 6E 39 39 34 61 43 61 72 74 00
//
// LAYER 2 — LZW-Compressed Payload (remaining bytes)
// ---------------------------------------------------
//   Everything after byte 12 is a single LZW-compressed data stream.
//   See "LZW Algorithm" below for decompression details.
//
// LAYER 3 — Decompressed Data Layout
// -----------------------------------
//   Offset  Type       Description
//   +0      WORD (LE)  Title/description string length in bytes
//   +2      STRING     Title text (ASCII/UTF-8, length from above)
//   +N      WORD (LE)  Number of cartridge data blocks
//
//   Then, for each block:
//     +0    BYTE       Block type (memory destination selector)
//     +1    WORD (LE)  Data size in bytes
//     +3    WORD (LE)  Address/offset in destination memory
//     +5    DATA       Raw data bytes (count = data_size)
//
//   After all blocks:
//     +0    DWORD (LE) System state size (typically ~222,010 bytes)
//     +4    DATA       Full Win994a emulator state snapshot (ignored)
//
// BLOCK TYPES
// -----------
//   Type   Destination
//   1-8    GROM chip data. The address field selects the chip:
//            0x6000 = chip 0, 0x8000 = chip 1, 0xA000 = chip 2,
//            0xC000 = chip 3, etc.
//          Each chip stores 6KB (0x1800 bytes) of active data.
//          The remaining 2KB per 8KB GROM slot is unused padding.
//   9      Secondary memory buffer (not used for cartridge loading)
//   10     System memory (not used for cartridge loading)
//   11-12  ROM bank 1 — CPU ROM at >6000-7FFF (8KB)
//   13     ROM bank 2 — Bank-switched ROM (8KB, second bank)
//
// ROM BYTE ORDER
// --------------
//   ROM block data is stored with bytes swapped within each 16-bit word
//   (little-endian word order). The TMS9900 CPU is big-endian, so ROM
//   data must be byte-swapped in pairs before use.
//   Example: TiCart bytes [CD AB] → TMS9900 word 0xABCD
//
// ============================================================================
// LZW Compression Algorithm
// ============================================================================
//
// Custom variant of LZW with explicit code-width change signals.
//
// Parameters:
//   - Bit order:            MSB first (bit 7 read first within each byte)
//   - Initial code width:   9 bits
//   - Maximum code width:   15 bits
//   - Dictionary capacity:  35,023 entries (prime number 0x88CF)
//   - First dictionary code: 259 (0x103)
//
// Special Codes:
//   Code  Meaning
//   256   End of stream (stop decompression)
//   257   Increase code width by 1 bit (e.g. 9→10→11...→15)
//   258   Clear dictionary (reset to initial state, width back to 9)
//   259+  Standard LZW dictionary entries
//
// Key difference from standard LZW: code width increases are EXPLICIT
// (signaled by code 257) rather than implicit. Standard LZW automatically
// widens when the dictionary fills to the current max code; this variant
// sends an explicit signal instead.
//
// Otherwise, standard LZW rules apply:
//   - Read code; if known, output its string; if code == nextCode,
//     output prevString + prevString[0]
//   - Add dictionary entry: prevString + currentString[0]
//   - Repeat until EOF (code 256)
//
// ============================================================================

import Foundation

struct TICartLoader {

    enum TiCartError: LocalizedError {
        case invalidMagic
        case decompressFailed
        case truncatedData
        case noCartridgeBlocks

        var errorDescription: String? {
            switch self {
            case .invalidMagic: return "Not a valid TiCart file (bad magic header)."
            case .decompressFailed: return "Failed to decompress TiCart data."
            case .truncatedData: return "TiCart file is truncated or corrupt."
            case .noCartridgeBlocks: return "No ROM or GROM data found in TiCart file."
            }
        }
    }

    /// The 12-byte magic header at the start of every TiCart file
    private static let magic: [UInt8] = Array("Win994aCart\0".utf8)

    /// Load a .TiCart file and return a CartridgeImage
    static func load(from url: URL) throws -> CartridgeImage {
        let data = try Data(contentsOf: url)
        guard data.count > 12 else { throw TiCartError.invalidMagic }

        // Verify magic header
        let header = [UInt8](data.prefix(12))
        guard header == magic else { throw TiCartError.invalidMagic }

        // Decompress the LZW payload
        let compressed = [UInt8](data.dropFirst(12))
        guard let decompressed = lzwDecompress(compressed) else {
            throw TiCartError.decompressFailed
        }

        // Parse the decompressed data
        return try parsePayload(decompressed, sourceURL: url)
    }

    /// Check if data starts with the TiCart magic header
    static func isTiCart(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        return [UInt8](data.prefix(12)) == magic
    }

    // MARK: - Payload Parser

    private static func parsePayload(_ data: [UInt8], sourceURL: URL) throws -> CartridgeImage {
        var offset = 0

        // Read title: WORD (LE) length + string bytes
        guard offset + 2 <= data.count else { throw TiCartError.truncatedData }
        let titleLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2

        var title = "TiCart"
        if titleLen > 0 && offset + titleLen <= data.count {
            title = String(bytes: data[offset..<(offset + titleLen)], encoding: .utf8)
                ?? String(bytes: data[offset..<(offset + titleLen)], encoding: .ascii)
                ?? "TiCart"
            offset += titleLen
        }

        // Read block count: WORD (LE)
        guard offset + 2 <= data.count else { throw TiCartError.truncatedData }
        let blockCount = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2

        // Parse data blocks

        // Parse blocks and assemble GROM + ROM data
        // GROM: up to 40KB (5 chips × 8KB), stored as 6KB active + 2KB padding per chip
        var gromChips: [Int: [UInt8]] = [:]  // chip index -> data
        var romBank1: [UInt8]?  // First 8KB ROM bank
        var romBank2: [UInt8]?  // Second 8KB ROM bank (bank-switched)

        for blockIdx in 0..<blockCount {
            guard offset + 5 <= data.count else {
                print("[TiCart] Warning: truncated at block \(blockIdx)")
                break
            }

            let blockType = Int(data[offset])
            offset += 1
            let blockSize = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
            let blockAddr = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2

            guard offset + blockSize <= data.count else {
                print("[TiCart] Warning: block \(blockIdx) truncated (need \(blockSize), have \(data.count - offset))")
                break
            }

            let blockData = Array(data[offset..<(offset + blockSize)])
            offset += blockSize

            switch blockType {
            case 1...8:
                // GROM chips — address tells us which chip
                // 0x6000 = chip 0, 0x8000 = chip 1, 0xA000 = chip 2, etc.
                // Each chip is 6KB (0x1800) of active data
                let chipIndex: Int
                if blockAddr >= 0x6000 {
                    chipIndex = (blockAddr - 0x6000) / 0x2000
                } else {
                    chipIndex = blockAddr / 0x2000
                }
                gromChips[chipIndex] = blockData

            case 11, 12:
                // ROM bank 1 (primary, at >6000-7FFF)
                // TiCart stores ROM words in little-endian; TMS9900 is big-endian
                romBank1 = byteSwapWords(blockData)

            case 13:
                // ROM bank 2 (bank-switched)
                romBank2 = byteSwapWords(blockData)

            default:
                // Types 9, 10, and others — skip (system memory, state data)
                break
            }
        }

        // Assemble GROM data: concatenate chips in order, padding each to 8KB
        var gromData: Data?
        if !gromChips.isEmpty {
            let maxChip = gromChips.keys.max() ?? 0
            var grom = Data()
            for chip in 0...maxChip {
                if let chipData = gromChips[chip] {
                    grom.append(contentsOf: chipData)
                    // Pad to 8KB boundary if chip data is less than 8KB
                    let remainder = chipData.count % 8192
                    if remainder != 0 {
                        grom.append(contentsOf: [UInt8](repeating: 0, count: 8192 - remainder))
                    }
                } else {
                    // Empty chip slot — fill with zeros
                    grom.append(contentsOf: [UInt8](repeating: 0, count: 8192))
                }
            }
            gromData = grom
        }

        // Assemble ROM data
        var romData: Data?
        var cartType: CartridgeType = .rom
        if let bank1 = romBank1 {
            if let bank2 = romBank2 {
                // Two banks — banked cartridge (non-inverted, matching Win994a behavior)
                var rom = Data(bank1)
                // Pad bank 1 to 8KB if needed
                if rom.count < 8192 {
                    rom.append(contentsOf: [UInt8](repeating: 0, count: 8192 - rom.count))
                }
                var b2 = Data(bank2)
                if b2.count < 8192 {
                    b2.append(contentsOf: [UInt8](repeating: 0, count: 8192 - b2.count))
                }
                rom.append(b2)
                romData = rom
                cartType = .banked378
            } else {
                romData = Data(bank1)
            }
        }

        // Determine final type
        if romData == nil && gromData != nil {
            cartType = .grom
        }

        guard romData != nil || gromData != nil else {
            throw TiCartError.noCartridgeBlocks
        }

        // Use the filename for the cart name (the embedded title is a long description)
        let name = sourceURL.deletingPathExtension().lastPathComponent

        return CartridgeImage(
            name: name,
            type: cartType,
            romData: romData,
            gromData: gromData,
            sourceURL: sourceURL
        )
    }

    /// Swap bytes within each 16-bit word.
    /// TiCart stores ROM data in little-endian word order; TMS9900 expects big-endian.
    private static func byteSwapWords(_ data: [UInt8]) -> [UInt8] {
        var result = data
        for i in stride(from: 0, to: result.count - 1, by: 2) {
            result.swapAt(i, i + 1)
        }
        return result
    }

    // MARK: - LZW Decompressor

    /// Custom LZW decompression matching Win994a's algorithm.
    /// - MSB-first bit reading
    /// - Initial code width: 9 bits
    /// - Max code width: 15 bits
    /// - Special codes: 256=EOF, 257=increase width, 258=clear dictionary
    /// - Dictionary entries start at code 259
    private static func lzwDecompress(_ input: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []

        // Bit reader state
        var bitPos = 0  // current bit position in input stream
        var codeWidth = 9

        // Dictionary: each entry is (prefix code, append byte)
        // We reconstruct strings by walking the chain
        struct DictEntry {
            let prefix: Int   // -1 for single-byte entries
            let byte: UInt8
            let length: Int   // cached length for performance
        }

        let maxDictSize = 35023  // Prime number 0x88CF, matching Win994a
        var dict: [DictEntry] = []
        var nextCode = 259  // First available dictionary code

        /// Read a variable-width code from the bit stream (MSB first)
        func readCode() -> Int? {
            guard bitPos + codeWidth <= input.count * 8 else { return nil }
            var code = 0
            for i in 0..<codeWidth {
                let byteIdx = (bitPos + i) / 8
                let bitIdx = 7 - ((bitPos + i) % 8)  // MSB first
                if input[byteIdx] & (1 << bitIdx) != 0 {
                    code |= 1 << (codeWidth - 1 - i)
                }
            }
            bitPos += codeWidth
            return code
        }

        /// Decode a code into its byte string by walking the dictionary chain
        func decodeString(_ code: Int) -> [UInt8]? {
            if code < 256 {
                return [UInt8(code)]
            }
            guard code >= 259 && (code - 259) < dict.count else { return nil }

            // Walk the chain, collecting bytes in reverse
            var bytes: [UInt8] = []
            var current = code
            while current >= 259 {
                let entry = dict[current - 259]
                bytes.append(entry.byte)
                current = entry.prefix
            }
            // current is now a single-byte code (0-255)
            bytes.append(UInt8(current))
            bytes.reverse()
            return bytes
        }

        /// Get the first byte of a code's decoded string
        func firstByte(of code: Int) -> UInt8 {
            var current = code
            while current >= 259 {
                let entry = dict[current - 259]
                current = entry.prefix
            }
            return UInt8(current)
        }

        // Read the first code
        guard var prevCode = readCode() else { return nil }
        if prevCode == 256 { return output }  // Immediate EOF

        // Handle special codes at start
        while prevCode == 257 || prevCode == 258 {
            if prevCode == 257 { codeWidth += 1 }
            if prevCode == 258 {
                dict.removeAll(keepingCapacity: true)
                nextCode = 259
                codeWidth = 9
            }
            guard let c = readCode() else { return nil }
            prevCode = c
            if prevCode == 256 { return output }
        }

        // First code must be a literal byte (0-255)
        guard prevCode < 256 else { return nil }
        output.append(UInt8(prevCode))

        // Main decompression loop
        while true {
            guard let code = readCode() else { break }

            if code == 256 {
                // End of stream
                break
            }

            if code == 257 {
                // Increase code width
                codeWidth += 1
                if codeWidth > 15 { codeWidth = 15 }
                continue
            }

            if code == 258 {
                // Clear dictionary
                dict.removeAll(keepingCapacity: true)
                nextCode = 259
                codeWidth = 9

                // Read next code as new start
                guard let newCode = readCode() else { break }
                if newCode == 256 { break }
                if newCode == 257 {
                    codeWidth += 1
                    continue
                }
                if newCode < 256 {
                    output.append(UInt8(newCode))
                    prevCode = newCode
                }
                continue
            }

            // Regular LZW code
            let decoded: [UInt8]
            if code < 256 {
                // Literal byte
                decoded = [UInt8(code)]
            } else if code < nextCode {
                // Known dictionary entry
                guard let s = decodeString(code) else { break }
                decoded = s
            } else if code == nextCode {
                // Special case: code not yet in dictionary
                // String = previous string + first byte of previous string
                guard let prevString = decodeString(prevCode) else { break }
                decoded = prevString + [prevString[0]]
            } else {
                // Invalid code
                print("[TiCart LZW] Invalid code \(code) (nextCode=\(nextCode))")
                break
            }

            output.append(contentsOf: decoded)

            // Add new dictionary entry: prevCode's string + first byte of current string
            if nextCode < maxDictSize {
                let entry = DictEntry(
                    prefix: prevCode,
                    byte: decoded[0],
                    length: (prevCode < 256 ? 1 : (prevCode >= 259 && prevCode - 259 < dict.count ? dict[prevCode - 259].length : 1)) + 1
                )
                dict.append(entry)
                nextCode += 1
            }

            prevCode = code
        }

        return output
    }
}
