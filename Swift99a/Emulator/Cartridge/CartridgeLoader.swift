// Swift 99/a
//
// CartridgeLoader.swift
// Loads cartridge images from disk files with auto-detection of type and format.
//
// Supports several loading modes:
//   - Single file: type inferred from filename suffix (C=ROM, G=GROM, 8=banked378, etc.)
//   - Paired files: explicit ROM + GROM URL pair
//   - Multi-file: groups files by suffix convention (C/D/G/8/9) and assembles them
//
// Also handles GRAMKracker 6-byte headers (auto-stripped when detected) and
// TiCart format files (delegated to TICartLoader).

import Foundation

struct CartridgeLoader {

    enum LoadError: LocalizedError {
        case fileReadFailed(URL)
        case emptyFile
        case fileTooLarge
        case noCartridgeData

        var errorDescription: String? {
            switch self {
            case .fileReadFailed(let url): return "Could not read file: \(url.lastPathComponent)"
            case .emptyFile: return "The cartridge file is empty."
            case .fileTooLarge: return "The cartridge file is too large (max 512KB for ROM, 64KB for GROM)."
            case .noCartridgeData: return "No valid cartridge data found."
            }
        }
    }

    /// Load a cartridge from a single file, auto-detecting type from filename
    static func load(from url: URL) throws -> CartridgeImage {
        let data = try loadFileData(url)
        let detectedType = detectType(from: url, fileSize: data.count)
        let strippedData = stripHeader(data, type: detectedType)
        let name = cartridgeName(from: url)

        switch detectedType {
        case .grom:
            guard strippedData.count <= 64 * 1024 else { throw LoadError.fileTooLarge }
            return CartridgeImage(name: name, type: .grom, romData: nil, gromData: strippedData, sourceURL: url)
        default:
            guard strippedData.count <= 512 * 1024 else { throw LoadError.fileTooLarge }
            return CartridgeImage(name: name, type: detectedType, romData: strippedData, gromData: nil, sourceURL: url)
        }
    }

    /// Load a cartridge from paired ROM + GROM files
    static func loadPair(romURL: URL?, gromURL: URL?) throws -> CartridgeImage {
        guard romURL != nil || gromURL != nil else { throw LoadError.noCartridgeData }

        var romData: Data?
        var gromData: Data?
        var name = "Cartridge"

        if let romURL = romURL {
            let raw = try loadFileData(romURL)
            romData = stripHeader(raw, type: .rom)
            name = cartridgeName(from: romURL)
            guard romData!.count <= 512 * 1024 else { throw LoadError.fileTooLarge }
        }

        if let gromURL = gromURL {
            let raw = try loadFileData(gromURL)
            gromData = stripHeader(raw, type: .grom)
            if romData == nil { name = cartridgeName(from: gromURL) }
            guard gromData!.count <= 64 * 1024 else { throw LoadError.fileTooLarge }
        }

        let type: CartridgeType
        if let rom = romData, rom.count > 8192 {
            type = .banked378
        } else if romData != nil {
            type = .rom
        } else {
            type = .grom
        }

        return CartridgeImage(name: name, type: type, romData: romData, gromData: gromData, sourceURL: romURL ?? gromURL)
    }

    /// Load a cartridge from multiple selected files (C=ROM, D=ROM bank2, G=GROM)
    /// Groups files by suffix convention and assembles the complete cartridge image.
    static func loadMultiple(from urls: [URL]) throws -> CartridgeImage {
        guard !urls.isEmpty else { throw LoadError.noCartridgeData }

        // If only one file, use single-file loader
        if urls.count == 1 { return try load(from: urls[0]) }

        // Categorize files by suffix
        var romURLs: [URL] = []    // C suffix (primary ROM bank)
        var rom2URLs: [URL] = []   // D suffix (second ROM bank)
        var gromURLs: [URL] = []   // G suffix (GROM)
        var banked8URLs: [URL] = [] // 8 suffix (banked 378)
        var banked9URLs: [URL] = [] // 9 or 3 suffix (banked 379)
        var otherURLs: [URL] = []

        for url in urls {
            let filename = url.deletingPathExtension().lastPathComponent.uppercased()
            guard let lastChar = filename.last else {
                otherURLs.append(url)
                continue
            }
            switch lastChar {
            case "C": romURLs.append(url)
            case "D": rom2URLs.append(url)
            case "G": gromURLs.append(url)
            case "8": banked8URLs.append(url)
            case "9", "3": banked9URLs.append(url)
            default: otherURLs.append(url)
            }
        }

        // Build combined ROM data
        var romData: Data?
        var name = "Cartridge"
        var detectedType: CartridgeType = .rom

        // Load primary ROM (C files or banked files)
        let primaryROMURL = romURLs.first ?? banked8URLs.first ?? banked9URLs.first ?? otherURLs.first
        if let url = primaryROMURL {
            let raw = try loadFileData(url)
            romData = stripHeader(raw, type: .rom)
            name = cartridgeName(from: url)
        }

        // If we have a D file (second bank), append it to make a banked cart
        // If we have a D file (second bank), append it to make a banked cart
        if let url = rom2URLs.first {
            let raw = try loadFileData(url)
            let bank2 = stripHeader(raw, type: .rom)
            if romData != nil {
                romData!.append(bank2)
                // C + D pair → 16KB cart with non-inverted bank switching
                // (paged378 / "TYPE_XB"). The D-suffix file is conventionally
                // bank 1 of a two-bank ROM; bank selection is by even/odd
                // address bit on a write to cart space.
                detectedType = .banked378
            } else {
                romData = bank2
                name = cartridgeName(from: url)
            }
        }

        // Determine type from ROM size if not already set by D file
        if detectedType == .rom, let rom = romData {
            if !banked9URLs.isEmpty {
                detectedType = .banked379
            } else if !banked8URLs.isEmpty || rom.count > 8192 {
                detectedType = .banked378
            }
        }

        guard (romData?.count ?? 0) <= 512 * 1024 else { throw LoadError.fileTooLarge }

        // Load GROM data
        var gromData: Data?
        if let url = gromURLs.first {
            let raw = try loadFileData(url)
            gromData = stripHeader(raw, type: .grom)
            if romData == nil { name = cartridgeName(from: url) }
            guard gromData!.count <= 64 * 1024 else { throw LoadError.fileTooLarge }
        }

        guard romData != nil || gromData != nil else { throw LoadError.noCartridgeData }

        // If we only have GROM, type is .grom
        if romData == nil { detectedType = .grom }

        return CartridgeImage(name: name, type: detectedType, romData: romData, gromData: gromData, sourceURL: urls.first)
    }

    // MARK: - Private Helpers

    private static func loadFileData(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            if (try? Data(contentsOf: url)) != nil {
                throw LoadError.emptyFile
            }
            throw LoadError.fileReadFailed(url)
        }
        return data
    }

    /// Auto-detect cartridge type from the character before the file extension
    /// Convention: alpinerc.bin → 'c' → ROM, alpinerg.bin → 'g' → GROM, etc.
    private static func detectType(from url: URL, fileSize: Int) -> CartridgeType {
        let filename = url.deletingPathExtension().lastPathComponent.uppercased()

        // Check the last character of the filename (before extension)
        if let lastChar = filename.last {
            switch lastChar {
            case "C": return .rom
            case "G": return .grom
            case "8": return .banked378
            case "9", "3": return .banked379
            case "!": return .mbx
            default: break
            }
        }

        // Fallback: use file size
        if fileSize <= 8192 {
            return .rom
        } else {
            return .banked378
        }
    }

    /// Strip GRAMKracker 6-byte header if present
    private static func stripHeader(_ data: Data, type: CartridgeType) -> Data {
        guard data.count > 6 else { return data }

        let firstByte = data[0]
        if firstByte == 0x00 || firstByte == 0xFF {
            // Check if bytes 4-5 look like a load address (0x6000 for ROM, 0x0000 for GROM)
            let possibleAddr = Int(data[4]) << 8 | Int(data[5])
            let expectedAddr = (type == .grom) ? 0x0000 : 0x6000
            if possibleAddr == expectedAddr {
                return data.dropFirst(6)
            }
        }

        return data
    }

    private static func cartridgeName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // Strip type suffix character if present
        let suffixes: Set<Character> = ["C", "c", "G", "g", "8", "9", "3"]
        if let last = name.last, suffixes.contains(last), name.count > 1 {
            name = String(name.dropLast())
        }
        return name
    }
}
