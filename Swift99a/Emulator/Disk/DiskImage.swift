// Swift 99/a
//
// DiskImage.swift
// V9T9-format sector-based disk image management.
//
// A V9T9 disk image is a flat binary file containing 256-byte sectors.
// Standard sizes:
//   - SSSD (Single-Sided Single-Density): 360 sectors = 90 KB
//   - DSSD (Double-Sided Single-Density): 720 sectors = 180 KB
//
// Sector 0 contains the Volume Information Block (disk name, total sectors,
// sectors/track, etc.) and the sector allocation bitmap.
// Sectors 1+ contain File Descriptor Records (FDRs) in the directory and
// data sectors. The directory is a flat catalog at sector 1.

import Foundation

final class DiskImage {

    let url: URL
    var isWriteProtected: Bool
    private var sectors: [[UInt8]]  // Array of 256-byte sectors
    private var isDirty: Bool = false

    var sectorCount: Int { sectors.count }

    /// Number of sectors marked as used in the sector 0 allocation bitmap.
    /// Used for synthesizing the disk-header record in directory listings.
    var usedSectorCount: Int {
        guard !sectors.isEmpty else { return 0 }
        let bitmap = sectors[0]
        var used = 0
        for s in 0..<sectorCount {
            let byteIdx = 56 + (s / 8)
            let bitIdx = s % 8
            if byteIdx < 256 && (bitmap[byteIdx] & (1 << bitIdx)) != 0 {
                used += 1
            }
        }
        return used
    }

    /// Disk name from sector 0 (bytes 0-9)
    var diskName: String {
        guard !sectors.isEmpty else { return "" }
        let sector0 = sectors[0]
        var name = ""
        for i in 0..<10 {
            let c = sector0[i]
            if c == 0 { break }
            name.append(Character(UnicodeScalar(c)))
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Init

    init(url: URL, data: Data, writeProtected: Bool = false) {
        self.url = url
        self.isWriteProtected = writeProtected

        // Split into 256-byte sectors
        let count = data.count / 256
        var sectorArray = [[UInt8]]()
        sectorArray.reserveCapacity(count)
        for i in 0..<count {
            let start = i * 256
            let end = min(start + 256, data.count)
            var sector = [UInt8](data[start..<end])
            // Pad to 256 if short
            while sector.count < 256 { sector.append(0) }
            sectorArray.append(sector)
        }
        self.sectors = sectorArray
    }

    // MARK: - Sector Access

    func readSector(_ number: Int) -> [UInt8]? {
        guard number >= 0 && number < sectors.count else { return nil }
        return sectors[number]
    }

    func writeSector(_ number: Int, data: [UInt8]) -> Bool {
        guard !isWriteProtected else { return false }
        guard number >= 0 && number < sectors.count else { return false }
        guard data.count == 256 else { return false }
        sectors[number] = data
        isDirty = true
        return true
    }

    // MARK: - File Catalog

    /// Get all FDR sector numbers from the catalog (sector 1)
    func catalogEntries() -> [(index: Int, fdrSector: Int)] {
        guard sectors.count > 1 else { return [] }
        let catalog = sectors[1]
        var entries: [(index: Int, fdrSector: Int)] = []
        for i in 0..<128 {
            let fdrSector = (Int(catalog[i * 2]) << 8) | Int(catalog[i * 2 + 1])
            if fdrSector != 0 {
                entries.append((index: i, fdrSector: fdrSector))
            }
        }
        return entries
    }

    /// Find an FDR by filename, return (catalog index, FDR sector number, parsed FDR)
    func findFile(_ name: String) -> (catalogIndex: Int, fdrSector: Int, fdr: FDR)? {
        let upperName = name.uppercased()
        for entry in catalogEntries() {
            guard let sectorData = readSector(entry.fdrSector) else { continue }
            let fdr = FDR.parse(from: sectorData)
            if fdr.fileName.uppercased() == upperName {
                return (entry.index, entry.fdrSector, fdr)
            }
        }
        return nil
    }

    /// Read all data sectors for a file into a single Data buffer
    func readFileData(fdr: FDR) -> Data {
        var fileData = Data()
        let fileSectors = fdr.allSectors()
        for sectorNum in fileSectors {
            if let sector = readSector(sectorNum) {
                fileData.append(contentsOf: sector)
            }
        }
        return fileData
    }

    // MARK: - Bitmap Management

    /// Check if a sector is free (from sector 0 bitmap)
    private func isSectorFree(_ sectorNum: Int) -> Bool {
        guard !sectors.isEmpty else { return false }
        let byteOffset = 56 + (sectorNum / 8)  // Bitmap starts at byte 56 in sector 0
        guard byteOffset < 256 else { return false }
        let bit = sectorNum % 8
        return sectors[0][byteOffset] & (1 << bit) == 0
    }

    /// Allocate a free sector, return sector number or nil
    private func allocateSector() -> Int? {
        for s in 2..<sectorCount {
            if isSectorFree(s) {
                markSector(s, used: true)
                return s
            }
        }
        return nil
    }

    /// Mark a sector as used/free in the bitmap
    private func markSector(_ sectorNum: Int, used: Bool) {
        let byteOffset = 56 + (sectorNum / 8)
        guard byteOffset < 256 else { return }
        let bit = sectorNum % 8
        if used {
            sectors[0][byteOffset] |= (1 << bit)
        } else {
            sectors[0][byteOffset] &= ~(1 << bit)
        }
        isDirty = true
    }

    // MARK: - File Write Operations

    /// Write file data back to disk sectors, updating FDR and catalog
    func writeFile(name: String, data: Data, fdr: inout FDR, isNew: Bool) -> Bool {
        guard !isWriteProtected else { return false }

        let sectorsNeeded = (data.count + 255) / 256

        // Get existing sectors or allocate new ones
        var fileSectors: [Int]
        if isNew {
            fileSectors = []
            for _ in 0..<sectorsNeeded {
                guard let s = allocateSector() else {
                    // Free already allocated sectors
                    for allocated in fileSectors { markSector(allocated, used: false) }
                    return false
                }
                fileSectors.append(s)
            }
        } else {
            fileSectors = fdr.allSectors()
            // Free extra sectors if file shrank
            while fileSectors.count > sectorsNeeded {
                let s = fileSectors.removeLast()
                markSector(s, used: false)
            }
            // Allocate more if file grew
            while fileSectors.count < sectorsNeeded {
                guard let s = allocateSector() else { return false }
                fileSectors.append(s)
            }
        }

        // Write data to sectors
        for (i, sectorNum) in fileSectors.enumerated() {
            let start = i * 256
            let end = min(start + 256, data.count)
            var sectorData = [UInt8](data[start..<end])
            while sectorData.count < 256 { sectorData.append(0) }
            _ = writeSector(sectorNum, data: sectorData)
        }

        // Update FDR
        fdr.sectorCount = sectorsNeeded
        fdr.clusters = buildClusterList(from: fileSectors)

        // Write FDR to its sector
        if isNew {
            // Allocate FDR sector
            guard let fdrSector = allocateSector() else { return false }
            let fdrData = encodeFDR(fdr)
            _ = writeSector(fdrSector, data: fdrData)

            // Add to catalog (sector 1)
            if let slotIndex = firstFreeCatalogSlot() {
                sectors[1][slotIndex * 2] = UInt8((fdrSector >> 8) & 0xFF)
                sectors[1][slotIndex * 2 + 1] = UInt8(fdrSector & 0xFF)
                isDirty = true
            } else {
                return false  // Catalog full
            }
        } else {
            // Find and update existing FDR sector
            if let found = findFile(name) {
                let fdrData = encodeFDR(fdr)
                _ = writeSector(found.fdrSector, data: fdrData)
            }
        }

        return true
    }

    /// Delete a file from the disk
    func deleteFile(_ name: String) -> Bool {
        guard !isWriteProtected else { return false }
        guard let found = findFile(name) else { return false }

        // Free all data sectors
        for sectorNum in found.fdr.allSectors() {
            markSector(sectorNum, used: false)
        }

        // Free FDR sector
        markSector(found.fdrSector, used: false)

        // Clear catalog entry
        sectors[1][found.catalogIndex * 2] = 0
        sectors[1][found.catalogIndex * 2 + 1] = 0
        isDirty = true

        return true
    }

    // MARK: - Save to File

    func saveIfDirty() {
        guard isDirty else { return }
        var allData = Data()
        for sector in sectors {
            allData.append(contentsOf: sector)
        }
        do {
            try allData.write(to: url)
            isDirty = false
        } catch {
            // Surface the failure — most often this is the macOS app sandbox
            // denying write access to a user-selected file when the
            // `com.apple.security.files.user-selected.read-write` entitlement
            // isn't enabled. Leaving isDirty=true so a later retry can succeed
            // if the situation changes.
            print("[Swift 99/a] Failed to write disk image \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func firstFreeCatalogSlot() -> Int? {
        guard sectors.count > 1 else { return nil }
        let catalog = sectors[1]
        for i in 0..<128 {
            let entry = (Int(catalog[i * 2]) << 8) | Int(catalog[i * 2 + 1])
            if entry == 0 { return i }
        }
        return nil
    }

    private func buildClusterList(from sectorList: [Int]) -> [(start: Int, end: Int)] {
        guard !sectorList.isEmpty else { return [] }
        var clusters: [(start: Int, end: Int)] = []
        var start = sectorList[0]
        var end = start
        for i in 1..<sectorList.count {
            if sectorList[i] == end + 1 {
                end = sectorList[i]
            } else {
                clusters.append((start: start, end: end))
                start = sectorList[i]
                end = start
            }
        }
        clusters.append((start: start, end: end))
        return clusters
    }

    private func encodeFDR(_ fdr: FDR) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 256)

        // Filename (bytes 0-9, space-padded)
        let nameBytes = Array(fdr.fileName.utf8)
        for i in 0..<10 {
            data[i] = i < nameBytes.count ? nameBytes[i] : 0x20
        }

        data[12] = fdr.fileType
        data[13] = UInt8(fdr.recordsPerSector & 0xFF)
        data[14] = UInt8((fdr.sectorCount >> 8) & 0xFF)
        data[15] = UInt8(fdr.sectorCount & 0xFF)
        data[16] = UInt8(fdr.endOfFileOffset & 0xFF)
        data[17] = UInt8(fdr.recordLength & 0xFF)
        // Record count is little-endian
        data[18] = UInt8(fdr.recordCount & 0xFF)
        data[19] = UInt8((fdr.recordCount >> 8) & 0xFF)

        // Encode cluster list (bytes 28+)
        var offset = 28
        for cluster in fdr.clusters {
            guard offset + 2 < 256 else { break }
            let startSector = cluster.start
            let endOffset = cluster.end - cluster.start
            data[offset] = UInt8(startSector & 0xFF)
            data[offset + 1] = UInt8((startSector >> 8) & 0x0F) | UInt8((endOffset >> 8) << 4)
            data[offset + 2] = UInt8(endOffset & 0xFF)
            offset += 3
        }

        return data
    }
}

// MARK: - Loading

extension DiskImage {
    enum LoadError: LocalizedError {
        case readFailed(URL)
        case invalidSize
        case emptyImage

        var errorDescription: String? {
            switch self {
            case .readFailed(let url): return "Could not read disk image: \(url.lastPathComponent)"
            case .invalidSize: return "Disk image has an invalid size (must be a multiple of 256 bytes)."
            case .emptyImage: return "Disk image is empty."
            }
        }
    }

    static func load(from url: URL) throws -> DiskImage {
        guard let data = try? Data(contentsOf: url) else {
            throw LoadError.readFailed(url)
        }
        guard !data.isEmpty else { throw LoadError.emptyImage }
        guard data.count % 256 == 0 else { throw LoadError.invalidSize }
        return DiskImage(url: url, data: data)
    }
}
