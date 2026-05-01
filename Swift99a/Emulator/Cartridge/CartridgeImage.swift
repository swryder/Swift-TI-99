// Swift 99/a
//
// CartridgeImage.swift
// Data model for cartridge images: the type enum (banking style) and
// the CartridgeImage struct that holds loaded ROM/GROM data.

import Foundation

/// Cartridge ROM banking style
enum CartridgeType: String, CaseIterable {
    case rom         // Standard 8KB CPU ROM at 0x6000
    case grom        // GROM-only cartridge
    case banked378   // Non-inverted bank-switched (most common for large ROMs)
    case banked379   // Inverted bank-switched (FinalGROM and some third-party carts)
    case mbx         // MBX: lower 4KB fixed, upper 4KB banked, 1KB RAM
}

/// Represents a loaded cartridge with its ROM and/or GROM data
struct CartridgeImage {
    let name: String
    let type: CartridgeType
    let romData: Data?      // CPU ROM data (mapped at 0x6000-0x7FFF)
    let gromData: Data?     // GROM data (loaded into GROM space at 0x6000+)
    let sourceURL: URL?

    /// Number of 8KB banks in the ROM data
    var bankCount: Int {
        guard let rom = romData, rom.count > 0 else { return 0 }
        return max(1, rom.count / 8192)
    }

    /// Bank mask for bank-switched cartridges (0 = no banking)
    var bankMask: Int {
        let count = bankCount
        guard count > 1 else { return 0 }
        // Round up to next power of 2, minus 1
        var mask = 1
        while mask < count {
            mask <<= 1
        }
        return mask - 1
    }
}
