// Swift 99/a
//
// Speech ROM (SPCHROM.BIN) handler — ported from MAME spchrom.cpp
// license: BSD-3-Clause
// copyright-holders: Frank Palazzolo, Aaron Giles, Jonathan Gevaryahu, Raphael Nabet, Couriersud, Michael Zapf
//
// Emulates the TMS6100 speech ROM chip used in the TI-99/4A Speech Synthesizer.
// The chip has a 1-bit data bus and 4-bit address bus (multiplexed 5 times to
// provide an 18-bit byte address). Data is accessed serially, one bit at a time.
//
// Hardware notes:
//   - The real TI-99/4A Speech Synthesizer has TWO TMS6100 ROM chips.
//     Chip 1 covers addresses 0x00000–0x07FFF (32KB, the standard vocabulary).
//     Chip 2 covers addresses 0x08000+ (typically empty/not populated).
//   - When the address targets chip 2 and no ROM is present, the data line
//     floats high on real hardware. We return all-1s in that case, which the
//     TMS5220 interprets as energy index 0xF (a STOP frame), properly
//     terminating speech playback.
//
// Vocabulary structure (Binary Search Tree):
//   Extended Basic's CALL SAY navigates the speech ROM vocabulary using the
//   TMS5220's Load Address and Read Byte commands. The vocabulary is stored
//   as a BST at the start of the ROM:
//     - Each node: [length] [chars...] [left_ptr(2)] [right_ptr(2)]
//     - Length-0 entries are word terminators containing speech data addresses
//     - The BST is alphabetically ordered; left = lexicographically less,
//       right = lexicographically greater
//     - After matching all characters of a prefix, sub-entries follow for
//       words that extend that prefix
//
// Critical bug fix (loadPointer corruption):
//   When read() returned early for out-of-range addresses (chip 2 not present),
//   it originally did NOT clear loadPointer. After 5 Load Address commands set
//   loadPointer to 20, the early return left it there. Subsequent Load Address
//   commands shifted nibbles to bit positions 20, 24, 28... all beyond the
//   18-bit mask, making them no-ops. The ROM address could never be set again,
//   permanently breaking speech. Fixed by clearing loadPointer = 0 in both
//   early-return guard clauses.

import Foundation

private let addressMask = 0x3FFFF  // 18-bit address mask

final class SpeechROM {
    private var romData: [UInt8] = []
    private var address: Int = 0            // 18-bit address counter
    private var loadPointer: Int = 0       // which 4-bit nibble (0, 4, 8, 12, 16)
    private var romBitsCount: Int = 0      // bits already consumed from current byte (0-7)

    var isLoaded: Bool { !romData.isEmpty }

    // MARK: - Loading

    func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            print("[Swift 99/a] Failed to load speech ROM from \(url.lastPathComponent)")
            return false
        }
        romData = [UInt8](data)
        address = 0
        loadPointer = 0
        romBitsCount = 0
        print("[Swift 99/a] Loaded speech ROM: \(romData.count) bytes")
        return true
    }

    func load(data: [UInt8]) {
        romData = data
        address = 0
        loadPointer = 0
        romBitsCount = 0
    }

    // MARK: - Address Loading

    /// Load a 4-bit address nibble (called by LOAD ADDRESS command)
    /// Ported from speechrom_device::load_address()
    func loadAddress(_ nibble: UInt8) {
        let data = Int(nibble & 0x0F)
        address = ((address & ~(0xF << loadPointer)) | (data << loadPointer)) & addressMask
        loadPointer += 4
        romBitsCount = 8  // reset bit position — next read starts at beginning of byte
    }

    /// Full device reset — matches the speech ROM's documented device_reset.
    /// Resets the load pointer by loading a zero nibble, then performs an
    /// immediate dummy read so the address pointer is in a clean state.
    func deviceReset() {
        loadAddress(0)
        _ = read(1)
    }

    // MARK: - Serial Bit Reading

    /// Read `count` bits serially from the ROM.
    /// Ported from speechrom_device::read() — compatibility mode (non-reversed bit order).
    /// Returns bits packed MSB-first (matching the MAME convention).
    func read(_ count: Int) -> Int {
        // When address is beyond loaded ROM data, return all 1s (floating bus).
        // See header comment for why loadPointer must be cleared here.
        guard !romData.isEmpty else {
            loadPointer = 0
            return (1 << count) - 1
        }
        guard address < romData.count else {
            loadPointer = 0
            return (1 << count) - 1
        }

        var count = count

        // First read after load address: skip one bit (dummy read)
        if loadPointer != 0 {
            loadPointer = 0
            count -= 1
        }

        var val = 0
        var pos = 8 - romBitsCount

        // Get current byte with bits shifted to the current position
        var spchbyte = (Int(romData[address]) << pos) & 0xFF

        while count > 0 {
            val = (val << 1)
            if (spchbyte & 0x80) != 0 {
                val |= 1
            }
            spchbyte = (spchbyte << 1) & 0xFF
            count -= 1

            if pos == 7 {
                pos = 0
                address = (address + 1) & addressMask
                if address >= romData.count {
                    // Remaining bits float high (no ROM chip responding)
                    val = (val << count) | ((1 << count) - 1)
                    count = 0
                } else {
                    spchbyte = Int(romData[address])
                }
            } else {
                pos += 1
            }
        }
        romBitsCount = 8 - pos

        return val
    }

    /// Read and branch: reads a 14-bit address from the current ROM position,
    /// preserving the top 4 bits of the current address.
    /// Ported from speechrom_device::read_and_branch()
    func readAndBranch() {
        guard !romData.isEmpty else { return }

        if address < romData.count - 1 {
            address = (address & 0x3C000)
                | ((Int(romData[address]) << 8) | Int(romData[address + 1])) & 0x3FFF
        } else if address == romData.count - 1 {
            address = (address & 0x3C000)
                | ((Int(romData[address]) << 8) & 0x3FFF)
        } else {
            address = address & 0x3C000
        }

        romBitsCount = 8  // reset bit counter
    }

    // MARK: - Direct Read

    /// Read a full byte from the current address (for READ BYTE command)
    func readByte() -> UInt8 {
        return UInt8(read(8) & 0xFF)
    }
}
