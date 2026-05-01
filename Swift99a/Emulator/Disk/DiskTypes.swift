// Swift 99/a
//
// DiskTypes.swift
// Data types for the disk emulation subsystem:
//   - PABError/PABOpcode/FileMode: TI DSR protocol enums
//   - PAB: Peripheral Access Block structure (the TI's file operation request)
//   - OpenFileInfo: State for an open file (buffered data, current position)
//   - FDR: File Descriptor Record (on-disk file metadata with cluster lists)

import Foundation

// MARK: - PAB Error Codes

enum PABError: Int {
    case none           = 0  // No error
    case writeProtect   = 1  // Disk write-protected
    case badAttribute   = 2  // File mode/type mismatch
    case illegalOp      = 3  // Operation not allowed
    case bufferFull     = 4  // No free file slots
    case readPastEOF    = 5  // Read beyond end of file
    case deviceError    = 6  // Disk I/O error
    case fileError      = 7  // File not found / can't create
}

// MARK: - PAB Opcodes

enum PABOpcode: Int {
    case open    = 0
    case close   = 1
    case read    = 2
    case write   = 3
    case restore = 4
    case load    = 5
    case save    = 6
    case delete  = 7
    case scratch = 8
    case status  = 9
}

// MARK: - File Mode

enum FileMode: Int {
    case update  = 0
    case output  = 2
    case input   = 3
    case append  = 1
}

// MARK: - PAB (Peripheral Access Block)

struct PAB {
    var opcode: Int = 0
    var statusByte: UInt8 = 0
    var dataBufferAddress: Int = 0
    var recordLength: Int = 0
    var charCount: Int = 0
    var recordNumber: Int = 0
    var screenOffset: UInt8 = 0
    var nameLength: Int = 0
    var fileName: String = ""

    // Decoded from status byte
    var fileMode: Int { Int(statusByte & 0x03) }
    var isVariable: Bool { statusByte & 0x10 != 0 }
    var isInternal: Bool { statusByte & 0x08 != 0 }
    var isProgram: Bool { false }  // Determined from FDR, not PAB

    /// Read a PAB from VDP RAM at the given address
    static func read(from vdp: [UInt8], address: Int) -> PAB {
        var pab = PAB()
        let a = address & 0x3FFF
        pab.opcode = Int(vdp[a])
        pab.statusByte = vdp[a + 1]
        pab.dataBufferAddress = (Int(vdp[a + 2]) << 8) | Int(vdp[a + 3])
        pab.recordLength = Int(vdp[a + 4])
        pab.charCount = Int(vdp[a + 5])
        pab.recordNumber = (Int(vdp[a + 6]) << 8) | Int(vdp[a + 7])
        pab.screenOffset = vdp[a + 8]
        pab.nameLength = Int(vdp[a + 9])

        // Read filename
        var name = ""
        for i in 0..<pab.nameLength {
            let idx = (a + 10 + i) & 0x3FFF
            name.append(Character(UnicodeScalar(vdp[idx])))
        }
        pab.fileName = name

        return pab
    }

    /// Write PAB fields back to VDP RAM (status, charCount, recordNumber, screenOffset)
    func writeBack(to vdp: inout [UInt8], address: Int) {
        let a = address & 0x3FFF
        vdp[a + 1] = statusByte
        vdp[a + 4] = UInt8(recordLength & 0xFF)
        vdp[a + 5] = UInt8(charCount & 0xFF)
        vdp[a + 6] = UInt8((recordNumber >> 8) & 0xFF)
        vdp[a + 7] = UInt8(recordNumber & 0xFF)
        vdp[a + 8] = screenOffset
    }

    /// Set error code in the status byte (bits 7:5)
    mutating func setError(_ error: PABError) {
        statusByte = (statusByte & 0x1F) | UInt8(error.rawValue << 5)
    }

    /// Clear error bits
    mutating func clearError() {
        statusByte &= 0x1F
    }

    /// Extract just the filename after "DSKx." prefix
    var bareFileName: String {
        // fileName is like "DSK1.FILENAME" — strip the device prefix
        if let dotIndex = fileName.firstIndex(of: ".") {
            return String(fileName[fileName.index(after: dotIndex)...])
        }
        return fileName
    }

    /// Extract disk number from "DSKx." prefix (1-9)
    var diskNumber: Int {
        guard fileName.uppercased().hasPrefix("DSK"),
              fileName.count >= 4 else { return 0 }
        let idx = fileName.index(fileName.startIndex, offsetBy: 3)
        return Int(String(fileName[idx])) ?? 0
    }
}

// MARK: - Open File Info

/// Tracks state for an open file within a disk image
class OpenFileInfo {
    var isOpen: Bool = false
    var isDirty: Bool = false
    var fileName: String = ""
    var fileMode: Int = 0       // FileMode raw value
    var isVariable: Bool = false
    var isInternal: Bool = false
    var isProgram: Bool = false
    var recordLength: Int = 0
    var recordCount: Int = 0
    var currentRecord: Int = 0
    var recordsPerSector: Int = 0   // For fixed-length files: records per 256-byte sector

    // File data buffer (loaded on open)
    var data: Data = Data()

    // For variable-length files, track position within data
    var dataOffset: Int = 0
}

// MARK: - FDR (File Descriptor Record)

struct FDR {
    var fileName: String = ""       // 10 chars, space-padded
    var fileType: UInt8 = 0         // Bit flags
    var recordsPerSector: Int = 0
    var sectorCount: Int = 0        // Total sectors
    var endOfFileOffset: Int = 0
    var recordLength: Int = 0
    var recordCount: Int = 0        // Little-endian in raw FDR
    var clusters: [(start: Int, end: Int)] = []  // Sector ranges

    var isVariable: Bool { fileType & 0x80 != 0 }
    var isInternal: Bool { fileType & 0x02 != 0 }
    var isProgram:  Bool { fileType & 0x01 != 0 }
    var isProtected: Bool { fileType & 0x08 != 0 }

    /// Parse an FDR from a 256-byte sector
    static func parse(from sector: [UInt8]) -> FDR {
        var fdr = FDR()

        // Filename: bytes 0-9
        var name = ""
        for i in 0..<10 {
            let c = sector[i]
            if c == 0 { break }
            name.append(Character(UnicodeScalar(c)))
        }
        fdr.fileName = name.trimmingCharacters(in: .whitespaces)

        fdr.fileType = sector[12]
        fdr.recordsPerSector = Int(sector[13])
        fdr.sectorCount = (Int(sector[14]) << 8) | Int(sector[15])
        fdr.endOfFileOffset = Int(sector[16])
        fdr.recordLength = Int(sector[17])
        // Record count is little-endian at bytes 18-19
        fdr.recordCount = Int(sector[18]) | (Int(sector[19]) << 8)

        // Parse cluster list (bytes 28-255)
        var offset = 28
        while offset + 2 < 256 {
            let b0 = Int(sector[offset])
            let b1 = Int(sector[offset + 1])
            let b2 = Int(sector[offset + 2])

            // Start sector: low 8 bits from b0, high 4 bits from low nibble of b1
            let startSector = b0 | ((b1 & 0x0F) << 8)
            // End sector offset from b2 low nibble and b1 high nibble
            let endOffset = b2 | ((b1 & 0xF0) >> 4) << 8

            if startSector == 0 && offset > 28 { break }
            if startSector == 0 && endOffset == 0 { break }

            fdr.clusters.append((start: startSector, end: startSector + endOffset))
            offset += 3
        }

        return fdr
    }

    /// Get all sector numbers used by this file
    func allSectors() -> [Int] {
        var sectors: [Int] = []
        for cluster in clusters {
            for s in cluster.start...cluster.end {
                sectors.append(s)
            }
        }
        return sectors
    }
}
