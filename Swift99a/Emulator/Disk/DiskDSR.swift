// Swift 99/a
//
// DiskDSR.swift
// High-level emulation of the TI Disk Controller DSR (Device Service Routine).
//
// Rather than emulating the TMS9900-based disk controller hardware at the gate
// level, this peripheral builds a minimal DSR ROM stub with valid TI headers
// and uses PC interception to handle file operations in native Swift code.
//
// How it works:
//   1. A stub ROM at 0x4000–0x5FFF contains a valid DSR header (0xAA magic byte),
//      device name list (DSK1/DSK2/DSK3/DSK), and a subprogram list (FILES).
//   2. When the CPU's DSRLNK routine scans the ROM and jumps to an entry point,
//      a PC interceptor fires and handles the PAB (Peripheral Access Block)
//      operation directly against mounted V9T9 disk images.
//   3. Supported PAB operations: Open, Close, Read, Write, Restore, Load, Save,
//      Delete, and Status.
//
// File data is transferred between VDP RAM (where the TI stores PABs and
// file buffers) and the sector-based DiskImage objects.

import Foundation

final class DiskDSR: Peripheral {

    // Up to 3 disk drives (DSK1-DSK3)
    var diskImages: [Int: DiskImage] = [:]  // key = drive number (1-3)

    // Open files per drive (max 3 files per drive by default)
    private var openFiles: [String: OpenFileInfo] = [:]  // key = "driveNum:filename"

    // CRU state - whether this DSR is currently active
    var isActive: Bool = false

    // DSR ROM data (minimal stub with proper headers)
    private let dsrROM: [UInt8]

    // Reference to VDP for direct RAM access
    weak var vdp: TMS9918?

    // Scratchpad access constants (CPU address space)
    private let PAB_POINTER: UInt16 = 0x8356  // Points to period in device name

    init(core: EmulatorSystem) {
        // Build minimal DSR ROM stub
        // The TI DSRLNK scans for 0xAA at 0x4000, then searches device name list
        // Our stub has the header and device names, with entry points that we intercept
        var rom = [UInt8](repeating: 0, count: 8192)

        // Header byte (0x4000)
        rom[0x0000] = 0xAA  // Valid DSR header

        // Version (0x4001)
        rom[0x0001] = 0x01

        // Standard TI DSR ROM header layout:
        // >4002-4003: reserved
        // >4004-4005: power-up list pointer
        // >4006-4007: program list pointer
        // >4008-4009: DSR (device) name list pointer
        // >400A-400B: subprogram list pointer
        // >400C-400D: ISR list pointer

        // Reserved (0x4002-0x4003)
        rom[0x0002] = 0x00
        rom[0x0003] = 0x00

        // Pointer to power-up list (0x4004-0x4005) = 0x0000 (none)
        rom[0x0004] = 0x00
        rom[0x0005] = 0x00

        // Pointer to program list (0x4006-0x4007) = 0x0000 (none)
        rom[0x0006] = 0x00
        rom[0x0007] = 0x00

        // Pointer to DSR (device) name list (0x4008-0x4009) = 0x4010
        rom[0x0008] = 0x40
        rom[0x0009] = 0x10

        // Pointer to subprogram list (0x400A-0x400B) = 0x4040
        rom[0x000A] = 0x40
        rom[0x000B] = 0x40

        // Pointer to ISR list (0x400C-0x400D) = 0x0000 (none)
        rom[0x000C] = 0x00
        rom[0x000D] = 0x00

        // DSR name list entries at 0x4010 (linked list for DSK1, DSK2, DSK3)
        // Format: next-link (2 bytes), entry address (2 bytes), name length (1 byte), name (n bytes)

        // DSK1 entry at 0x4010
        rom[0x0010] = 0x40  // Next link = 0x4020
        rom[0x0011] = 0x20
        rom[0x0012] = 0x48  // Entry address = 0x4800
        rom[0x0013] = 0x00
        rom[0x0014] = 0x04  // Name length = 4
        rom[0x0015] = 0x44  // 'D'
        rom[0x0016] = 0x53  // 'S'
        rom[0x0017] = 0x4B  // 'K'
        rom[0x0018] = 0x31  // '1'

        // DSK2 entry at 0x4020
        rom[0x0020] = 0x40  // Next link = 0x4030
        rom[0x0021] = 0x30
        rom[0x0022] = 0x48  // Entry address = 0x4800
        rom[0x0023] = 0x00
        rom[0x0024] = 0x04  // Name length = 4
        rom[0x0025] = 0x44  // 'D'
        rom[0x0026] = 0x53  // 'S'
        rom[0x0027] = 0x4B  // 'K'
        rom[0x0028] = 0x32  // '2'

        // DSK3 entry at 0x4030
        rom[0x0030] = 0x00  // Next link = 0x0000 (end)
        rom[0x0031] = 0x00
        rom[0x0032] = 0x48  // Entry address = 0x4800
        rom[0x0033] = 0x00
        rom[0x0034] = 0x04  // Name length = 4
        rom[0x0035] = 0x44  // 'D'
        rom[0x0036] = 0x53  // 'S'
        rom[0x0037] = 0x4B  // 'K'
        rom[0x0038] = 0x33  // '3'

        // Subprogram list entry for "FILES" at 0x4040
        // Format: next-link (2 bytes), entry address (2 bytes), name length (1 byte), name (n bytes)
        rom[0x0040] = 0x00  // Next link = 0x0000 (end of list)
        rom[0x0041] = 0x00
        rom[0x0042] = 0x48  // Entry address = 0x4880
        rom[0x0043] = 0x80
        rom[0x0044] = 0x05  // Name length = 5
        rom[0x0045] = 0x46  // 'F'
        rom[0x0046] = 0x49  // 'I'
        rom[0x0047] = 0x4C  // 'L'
        rom[0x0048] = 0x45  // 'E'
        rom[0x0049] = 0x53  // 'S'

        // At 0x4880 (FILES subprogram entry), put B *R11 (return)
        rom[0x0880] = 0x04  // B *R11 = 0x045B
        rom[0x0881] = 0x5B

        // At 0x4800 (the entry point), put IDLE instruction (0x0340)
        // which signals to our interceptor that we need to handle this
        // Actually we'll intercept before the CPU executes, so put a
        // RT (return) instruction: RTWP = 0x0380
        // But the real approach: we intercept the PC before it runs at 0x4800
        rom[0x0800] = 0x04  // B *R11 (return to caller) = 0x045B
        rom[0x0801] = 0x5B

        self.dsrROM = rom
        super.init(core: core)
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "DiskDSR", index: index)
        return true
    }

    // The DSR ROM is gated by the CRU bit, so reads return 0 or the ROM byte
    // depending on isActive. The shadow fast-path can't reflect that, so force
    // every read through the virtual call.
    override var readsHaveSideEffects: Bool { true }

    // MARK: - Memory Read/Write (DSR ROM space 0x4000-0x5FFF)

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        if isIO {
            // CRU read - return activation state
            return isActive ? 1 : 0
        }

        // Memory read from DSR ROM
        guard isActive else { return 0 }
        guard addr < dsrROM.count else { return 0 }
        return dsrROM[addr]
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        if isIO {
            // CRU write - bit 0 activates/deactivates DSR
            if addr == 0 {
                isActive = (data != 0)
            }
            return
        }
        // DSR ROM is read-only, ignore writes
    }

    // MARK: - DSR Entry Interception

    /// Called by the CPU when PC reaches 0x4800 and disk DSR is active.
    /// Reads PAB from VDP RAM, dispatches the operation, writes results back.
    /// Returns true if the operation was handled (CPU should return from DSR).
    func handleDSREntry(cpu: TMS9900) -> Bool {
        guard isActive else { return false }
        guard let vdp = vdp else { return false }
        guard let core = theCore else { return false }

        // DSRLNK sets up two scratchpad values when calling the DSR entry:
        // >8356 = VDP pointer to the period (.) in the device name within the PAB
        // >8354 = length of the matched device name (e.g., 4 for "DSK1")
        // PAB base = >8356 - >8354 - 10 (10 bytes of PAB header before name field)
        var cycles = 0

        let ptr8356Hi = core.readMemoryByte(address: 0x8356, cycles: &cycles, accessType: .read)
        let ptr8356Lo = core.readMemoryByte(address: 0x8357, cycles: &cycles, accessType: .read)
        let periodPtr = (Int(ptr8356Hi) << 8) | Int(ptr8356Lo)

        let len8354Hi = core.readMemoryByte(address: 0x8354, cycles: &cycles, accessType: .read)
        let len8354Lo = core.readMemoryByte(address: 0x8355, cycles: &cycles, accessType: .read)
        let deviceNameLen = (Int(len8354Hi) << 8) | Int(len8354Lo)

        let pabBase = periodPtr - deviceNameLen - 10

        guard pabBase > 0 && pabBase < 0x4000 else { return false }

        // Read the PAB from VDP RAM
        var pab = PAB.read(from: vdp.VDP, address: pabBase)

        // Get drive number from filename
        let driveNum = pab.diskNumber
        guard driveNum >= 1 && driveNum <= 3 else {
            pab.setError(.deviceError)
            pab.writeBack(to: &vdp.VDP, address: pabBase)
            signalHandled(cpu: cpu)
            return true
        }

        // Check if we have a disk image mounted for this drive
        guard let disk = diskImages[driveNum] else {
            pab.setError(.deviceError)
            pab.writeBack(to: &vdp.VDP, address: pabBase)
            signalHandled(cpu: cpu)
            return true
        }

        let fileName = pab.bareFileName

        // Dispatch by opcode
        guard let opcode = PABOpcode(rawValue: pab.opcode) else {
            pab.setError(.illegalOp)
            pab.writeBack(to: &vdp.VDP, address: pabBase)
            signalHandled(cpu: cpu)
            return true
        }

        pab.clearError()

        switch opcode {
        case .open:    handleOpen(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .close:   handleClose(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .read:    handleRead(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .write:   handleWrite(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .restore: handleRestore(pab: &pab, drive: driveNum, fileName: fileName)
        case .load:    handleLoad(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .save:    handleSave(pab: &pab, disk: disk, drive: driveNum, fileName: fileName, vdp: vdp)
        case .delete:  handleDelete(pab: &pab, disk: disk, fileName: fileName)
        case .scratch:  pab.setError(.illegalOp)  // Not commonly needed
        case .status:  handleStatus(pab: &pab, disk: disk, fileName: fileName)
        }

        // Write PAB back to VDP
        pab.writeBack(to: &vdp.VDP, address: pabBase)

        // Signal to DSRLNK that we handled this request (INCT R11 + B *R11)
        // Errors are communicated via the PAB status byte, not the CPU return path
        signalHandled(cpu: cpu)

        return true
    }

    // MARK: - FILES Subprogram

    /// Called by the CPU when PC reaches 0x4880 and disk DSR is active.
    /// Implements CALL FILES(n) to adjust VDP RAM file buffer allocation.
    func handleFilesSubprogram(cpu: TMS9900) -> Bool {
        guard isActive else { return false }
        guard let vdp = vdp else { return false }
        guard let core = theCore else { return false }

        var cycles = 0

        // Read BASIC's next-token pointer from >832C
        let tokPtrHi = core.readMemoryByte(address: 0x832C, cycles: &cycles, accessType: .read)
        let tokPtrLo = core.readMemoryByte(address: 0x832D, cycles: &cycles, accessType: .read)
        var x = (Int(tokPtrHi) << 8) | Int(tokPtrLo)

        // Skip 7 bytes past the "FILES" token to reach the argument
        x += 7

        // Read two bytes from VDP: token type and string length
        let tokenType = vdp.VDP[x & 0x3FFF]
        let stringLen = vdp.VDP[(x + 1) & 0x3FFF]

        // Expect 0xC8 (unquoted string token) with length 1
        if tokenType == 0xC8 && stringLen == 0x01 {
            let digitByte = vdp.VDP[(x + 2) & 0x3FFF]
            let fileCount = Int(digitByte) - 0x30  // Convert ASCII digit to number

            if fileCount >= 0 && fileCount <= 9 {
                doFiles(count: fileCount, vdp: vdp, core: core)

                // Skip past the rest of the statement: advance token pointer
                x += 3
                core.writeMemoryByte(address: 0x832C, cycles: &cycles, accessType: .write, data: UInt8((x >> 8) & 0xFF))
                core.writeMemoryByte(address: 0x832D, cycles: &cycles, accessType: .write, data: UInt8(x & 0xFF))

                // Clear 'current' token at >8342
                core.writeMemoryByte(address: 0x8342, cycles: &cycles, accessType: .write, data: 0)
            }
        }

        // Return from subprogram: INCT R11, B *R11
        // The DSRLNK calls us via BL *R9, so R11 contains the return address.
        // Incrementing R11 by 2 signals "I handled it" to the DSRLNK scanner.
        signalHandled(cpu: cpu)

        return true
    }

    /// Adjust VDP RAM file buffer allocation for n files.
    /// Matches legacy BaseDisk::SetFiles() behavior.
    private func doFiles(count n: Int, vdp: TMS9918, core: EmulatorSystem) {
        // Close all open files
        openFiles.removeAll()

        if n > 0 {
            // Each file buffer = 518 bytes (256 data + 256 FDR + 6 tracking)
            // Formula: nNewTop = 0x3DEF - (518 * n) - 5 - 1
            let newTop = 0x3DEF - (518 * n) - 5 - 1

            // Write new top-of-VRAM pointer to scratchpad >8370-8371
            var cycles = 0
            core.writeMemoryByte(address: 0x8370, cycles: &cycles, accessType: .write, data: UInt8((newTop >> 8) & 0xFF))
            core.writeMemoryByte(address: 0x8371, cycles: &cycles, accessType: .write, data: UInt8(newTop & 0xFF))

            // Set up the VDP disk buffer header (5 bytes starting at newTop+1)
            var addr = newTop + 1
            vdp.VDP[addr & 0x3FFF] = 0xAA        // Valid header marker
            addr += 1
            vdp.VDP[addr & 0x3FFF] = 0x3F        // Top of VRAM, MSB (>3FFF)
            addr += 1
            vdp.VDP[addr & 0x3FFF] = 0xFF        // Top of VRAM, LSB
            addr += 1
            vdp.VDP[addr & 0x3FFF] = 0x11        // CRU address of disk controller (>11 = >1100 >> 8)
            addr += 1
            vdp.VDP[addr & 0x3FFF] = UInt8(n)    // Number of file buffers
        } else {
            // CALL FILES(0): no disk buffers, reset to top of VRAM
            var cycles = 0
            core.writeMemoryByte(address: 0x8370, cycles: &cycles, accessType: .write, data: 0x3F)
            core.writeMemoryByte(address: 0x8371, cycles: &cycles, accessType: .write, data: 0xFF)
        }
    }

    // MARK: - CPU Return Signaling

    /// Signal that this DSR handled the request: INCT R11, B *R11
    /// Used for both DSR device entries and subprogram entries.
    /// The DSRLNK calls us via BL *R9. R11 holds the return address within
    /// the DSRLNK scanning loop. Incrementing R11 by 2 skips the "keep scanning"
    /// jump, telling DSRLNK we handled the request.
    private func signalHandled(cpu: TMS9900) {
        let r11Addr = cpu.WP &+ 22   // R11 is at WP + 22
        let r11Value = cpu.romword(S: r11Addr)
        cpu.wrword(D: r11Addr, V: r11Value &+ 2)  // INCT R11
        cpu.setPC(r11Value &+ 2)                    // B *R11
    }

    /// Signal that this DSR did NOT handle the request: B *R11 (no increment)
    /// DSRLNK will continue scanning other peripheral cards.
    private func signalNotHandled(cpu: TMS9900) {
        let r11Addr = cpu.WP &+ 22
        let r11Value = cpu.romword(S: r11Addr)
        cpu.setPC(r11Value)  // B *R11 (no increment)
    }

    // MARK: - PAB Operations

    private func fileKey(drive: Int, name: String) -> String {
        "\(drive):\(name.uppercased())"
    }

    private func handleOpen(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        let key = fileKey(drive: drive, name: fileName)

        // Check if already open
        if openFiles[key] != nil {
            pab.setError(.illegalOp)
            return
        }

        // Empty filename ("DSK1.") = directory listing protocol. Synthesize a
        // virtual INTERNAL RELATIVE file containing the catalog as records.
        if fileName.isEmpty {
            openDirectoryListing(pab: &pab, disk: disk, drive: drive, key: key)
            return
        }

        // Find file on disk
        guard let found = disk.findFile(fileName) else {
            // File not found - only OK for OUTPUT or APPEND mode
            if pab.fileMode == FileMode.output.rawValue || pab.fileMode == FileMode.append.rawValue {
                // Create new empty file
                let info = OpenFileInfo()
                info.isOpen = true
                info.fileName = fileName
                info.fileMode = pab.fileMode
                info.isVariable = pab.isVariable
                info.isInternal = pab.isInternal
                info.recordLength = pab.recordLength > 0 ? pab.recordLength : 80
                info.recordCount = 0
                info.currentRecord = 0
                info.recordsPerSector = info.isVariable
                    ? max(1, 256 / (info.recordLength + 1))
                    : max(1, 256 / info.recordLength)
                info.data = Data()
                info.dataOffset = 0
                openFiles[key] = info

                if pab.recordLength == 0 {
                    pab.recordLength = 80
                }
                return
            }
            pab.setError(.fileError)
            return
        }

        let fdr = found.fdr

        // Load file data
        let fileData = disk.readFileData(fdr: fdr)

        let info = OpenFileInfo()
        info.isOpen = true
        info.fileName = fileName
        info.fileMode = pab.fileMode
        info.isVariable = fdr.isVariable
        info.isInternal = fdr.isInternal
        info.isProgram = fdr.isProgram
        info.recordLength = fdr.recordLength > 0 ? fdr.recordLength : (pab.recordLength > 0 ? pab.recordLength : 80)
        info.recordCount = fdr.recordCount
        info.currentRecord = 0
        info.recordsPerSector = fdr.recordsPerSector > 0
            ? fdr.recordsPerSector
            : (info.recordLength > 0 ? max(1, 256 / info.recordLength) : 1)
        info.data = fileData
        info.dataOffset = 0
        openFiles[key] = info

        // Update PAB with actual record length if user didn't specify
        if pab.recordLength == 0 {
            pab.recordLength = info.recordLength
        }
        pab.recordNumber = 0
    }

    // MARK: - Directory Listing Synthesis

    /// Standard DV80 record length for INTERNAL RELATIVE catalog records.
    /// 1 byte string-length + 10 bytes filename + 3 * (1 byte type + 8 byte FP)
    /// = 38 bytes, packing exactly 6 records per 256-byte sector.
    private static let directoryRecordLength = 38

    /// Open the synthetic directory listing for "DSKn." (empty filename).
    /// Builds an in-memory data buffer of fixed-length INTERNAL records, one
    /// per file plus a header and a terminator, and seeds an OpenFileInfo so
    /// the existing handleRead path serves them.
    private func openDirectoryListing(pab: inout PAB, disk: DiskImage, drive: Int, key: String) {
        let recordLength = Self.directoryRecordLength
        let recsPerSec = 256 / recordLength   // 6
        let data = buildDirectoryListing(disk: disk, recordLength: recordLength, recsPerSec: recsPerSec)

        let info = OpenFileInfo()
        info.isOpen = true
        info.fileName = ""
        // Force update mode so handleRead's `mode == input || mode == update`
        // gate passes regardless of what bit pattern BASIC put in the PAB for
        // RELATIVE INTERNAL OPEN — this synthetic file is read-only by nature.
        info.fileMode = FileMode.update.rawValue
        info.isVariable = false
        info.isInternal = true
        info.isProgram = false
        info.recordLength = recordLength
        info.recordCount = data.count / recordLength
        info.currentRecord = 0
        info.recordsPerSector = recsPerSec
        info.data = data
        info.dataOffset = 0
        openFiles[key] = info

        pab.recordLength = recordLength
        pab.recordNumber = 0
    }

    /// Build the directory listing as a byte buffer with the same sector
    /// padding the FDR-stored fixed-length files use, so handleRead's
    /// (recNum / recsPerSec) * 256 + (recNum % recsPerSec) * recLen math
    /// addresses records correctly.
    private func buildDirectoryListing(disk: DiskImage, recordLength: Int, recsPerSec: Int) -> Data {
        var out = [UInt8]()
        var recsInSec = 0
        let sectorPadBytes = 256 - recsPerSec * recordLength

        func append(_ rec: [UInt8]) {
            out.append(contentsOf: rec)
            recsInSec += 1
            if recsInSec == recsPerSec {
                out.append(contentsOf: [UInt8](repeating: 0, count: sectorPadBytes))
                recsInSec = 0
            }
        }

        // Record 0: disk header (name, total sectors, free sectors, 0)
        let total = disk.sectorCount
        let used = disk.usedSectorCount
        let free = max(0, total - used)
        append(internalRecord(string: disk.diskName, n1: total, n2: free, n3: 0, padTo: recordLength))

        // One record per file in the catalog
        for entry in disk.catalogEntries() {
            guard let fdrSector = disk.readSector(entry.fdrSector) else { continue }
            let fdr = FDR.parse(from: fdrSector)
            let typeCode = directoryFileTypeCode(fdr: fdr)
            append(internalRecord(string: fdr.fileName, n1: typeCode, n2: fdr.sectorCount, n3: fdr.recordLength, padTo: recordLength))
        }

        // Terminator: empty name + zeros. Catalog programs check `IF A=0`
        // (the first number after the name) to detect end-of-list.
        append(internalRecord(string: "", n1: 0, n2: 0, n3: 0, padTo: recordLength))

        // Pad the final partial sector so the data is a whole number of sectors.
        if recsInSec > 0 {
            let bytesUsed = recsInSec * recordLength
            out.append(contentsOf: [UInt8](repeating: 0, count: 256 - bytesUsed))
        }
        return Data(out)
    }

    /// TI catalog file-type code:
    ///   1=DIS/FIX, 2=DIS/VAR, 3=INT/FIX, 4=INT/VAR, 5=PROGRAM.
    /// Negative values indicate write-protected. We emit positive codes only;
    /// emitting negatives requires 100's-complement mantissa handling we
    /// haven't built and most catalog programs ignore the sign anyway.
    private func directoryFileTypeCode(fdr: FDR) -> Int {
        if fdr.isProgram { return 5 }
        if fdr.isInternal && fdr.isVariable { return 4 }
        if fdr.isInternal { return 3 }
        if fdr.isVariable { return 2 }
        return 1
    }

    /// One INTERNAL record: length-prefixed string + three length-prefixed
    /// (1 byte = 0x08) 8-byte TI radix-100 floating-point numbers, padded
    /// with zeros to `padTo` bytes.
    private func internalRecord(string: String, n1: Int, n2: Int, n3: Int, padTo: Int) -> [UInt8] {
        var rec = [UInt8]()
        rec.reserveCapacity(padTo)

        let strBytes = Array(string.utf8)
        let strLen = min(strBytes.count, 255)
        rec.append(UInt8(strLen))
        rec.append(contentsOf: strBytes.prefix(strLen))

        for n in [n1, n2, n3] {
            rec.append(0x08)
            rec.append(contentsOf: tiFloat(n))
        }

        while rec.count < padTo { rec.append(0) }
        return rec
    }

    /// Encode a non-negative integer as 8 bytes of TI radix-100 floating
    /// point. Format: byte 0 is biased exponent (0x40 = 100^0); bytes 1..7
    /// are big-endian mantissa, each in the range 0..99. Zero is all zeros.
    private func tiFloat(_ value: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        if value == 0 { return bytes }

        var n = abs(value)

        // Find exp such that 100^exp <= n < 100^(exp+1)
        var exp = 0
        var pow100 = 1
        while pow100 * 100 <= n {
            pow100 *= 100
            exp += 1
        }

        // Big-endian mantissa, base 100, in bytes 1..7
        for i in 0..<7 {
            if pow100 == 0 { break }
            let digit = n / pow100
            bytes[i + 1] = UInt8(digit & 0xFF)
            n -= digit * pow100
            pow100 = pow100 >= 100 ? pow100 / 100 : 0
        }

        bytes[0] = UInt8(0x40 + exp)
        if value < 0 { bytes[0] |= 0x80 }
        return bytes
    }

    private func handleClose(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        let key = fileKey(drive: drive, name: fileName)
        guard let info = openFiles[key] else { return }  // Not an error to close non-open file

        if info.isDirty {
            flushFile(info: info, disk: disk, fileName: fileName)
        }

        openFiles.removeValue(forKey: key)
    }

    private func handleRead(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        let key = fileKey(drive: drive, name: fileName)
        guard let info = openFiles[key], info.isOpen else {
            pab.setError(.illegalOp)
            return
        }

        // Check mode allows reading
        guard info.fileMode == FileMode.input.rawValue || info.fileMode == FileMode.update.rawValue else {
            pab.setError(.illegalOp)
            return
        }

        if info.isVariable {
            // Variable-length: read from current data offset
            if info.dataOffset >= info.data.count {
                pab.setError(.readPastEOF)
                return
            }

            // Scan sectors for variable records
            // Each 256-byte sector has: [len][data...][len][data...]...[0xFF padding]
            let sectorOffset = (info.dataOffset / 256) * 256
            var posInSector = info.dataOffset % 256

            if sectorOffset >= info.data.count {
                pab.setError(.readPastEOF)
                return
            }

            let recLen = Int(info.data[sectorOffset + posInSector])
            if recLen == 0xFF || posInSector + 1 + recLen > 256 {
                // Move to next sector
                info.dataOffset = sectorOffset + 256
                if info.dataOffset >= info.data.count {
                    pab.setError(.readPastEOF)
                    return
                }
                posInSector = 0
                let nextRecLen = Int(info.data[info.dataOffset])
                if nextRecLen == 0xFF {
                    pab.setError(.readPastEOF)
                    return
                }
                // Read this record
                let bytesToRead = min(nextRecLen, info.recordLength)
                writeToVDP(vdp: vdp, address: pab.dataBufferAddress, data: info.data, offset: info.dataOffset + 1, count: bytesToRead)
                pab.charCount = bytesToRead
                info.dataOffset += 1 + nextRecLen
            } else {
                let bytesToRead = min(recLen, info.recordLength)
                writeToVDP(vdp: vdp, address: pab.dataBufferAddress, data: info.data, offset: sectorOffset + posInSector + 1, count: bytesToRead)
                pab.charCount = bytesToRead
                info.dataOffset = sectorOffset + posInSector + 1 + recLen
            }

            info.currentRecord += 1
        } else {
            // Fixed-length: each sector holds recordsPerSector records of recordLength
            // bytes followed by padding (when recordLength * recsPerSec < 256). Compute
            // the byte offset by stepping in whole sectors and then within the sector.
            let recNum = pab.recordNumber
            let recsPerSec = max(1, info.recordsPerSector)
            let offset = (recNum / recsPerSec) * 256 + (recNum % recsPerSec) * info.recordLength
            if offset >= info.data.count {
                pab.setError(.readPastEOF)
                return
            }

            let bytesToRead = min(info.recordLength, info.data.count - offset)
            writeToVDP(vdp: vdp, address: pab.dataBufferAddress, data: info.data, offset: offset, count: bytesToRead)
            pab.charCount = bytesToRead
            pab.recordNumber = recNum + 1
            info.currentRecord = recNum + 1
        }
    }

    private func handleWrite(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        let key = fileKey(drive: drive, name: fileName)
        guard let info = openFiles[key], info.isOpen else {
            pab.setError(.illegalOp)
            return
        }

        guard info.fileMode == FileMode.output.rawValue ||
              info.fileMode == FileMode.update.rawValue ||
              info.fileMode == FileMode.append.rawValue else {
            pab.setError(.illegalOp)
            return
        }

        // Read data from VDP buffer
        let bytesToWrite = pab.charCount > 0 ? pab.charCount : info.recordLength
        var recordData = readFromVDP(vdp: vdp, address: pab.dataBufferAddress, count: bytesToWrite)

        if info.isVariable {
            // For variable-length, append record with length prefix
            // Simple approach: just append to data buffer
            var newRecord = Data()
            newRecord.append(UInt8(recordData.count))
            newRecord.append(contentsOf: recordData)
            info.data.append(newRecord)
        } else {
            // Fixed-length: write at record position, accounting for end-of-sector padding
            let recNum = pab.recordNumber
            let recsPerSec = max(1, info.recordsPerSector)
            let sector = recNum / recsPerSec
            let offset = sector * 256 + (recNum % recsPerSec) * info.recordLength

            // Extend data to a whole-sector boundary including this record
            let neededBytes = sector * 256 + 256
            while info.data.count < neededBytes {
                info.data.append(0)
            }

            // Pad record to full length
            while recordData.count < info.recordLength {
                recordData.append(0)
            }

            // Write record
            for i in 0..<info.recordLength {
                info.data[offset + i] = recordData[i]
            }

            pab.recordNumber = recNum + 1
            info.currentRecord = recNum + 1
        }

        info.recordCount = max(info.recordCount, info.currentRecord)
        info.isDirty = true
    }

    private func handleRestore(pab: inout PAB, drive: Int, fileName: String) {
        let key = fileKey(drive: drive, name: fileName)
        guard let info = openFiles[key], info.isOpen else {
            pab.setError(.illegalOp)
            return
        }
        info.currentRecord = 0
        info.dataOffset = 0
        pab.recordNumber = 0
    }

    private func handleLoad(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        // LOAD: read entire program file into VDP RAM
        guard let found = disk.findFile(fileName) else {
            pab.setError(.fileError)
            return
        }

        guard found.fdr.isProgram else {
            pab.setError(.badAttribute)
            return
        }

        let fileData = disk.readFileData(fdr: found.fdr)

        // Calculate actual file size from FDR (exclude padding in last sector)
        let fdr = found.fdr
        var actualSize: Int
        if fdr.sectorCount > 0 {
            if fdr.endOfFileOffset > 0 {
                actualSize = (fdr.sectorCount - 1) * 256 + fdr.endOfFileOffset
            } else {
                actualSize = fdr.sectorCount * 256
            }
        } else {
            actualSize = 0
        }
        actualSize = min(actualSize, fileData.count)

        // Clamp to VDP bounds
        let loadSize = min(actualSize, 0x4000 - pab.dataBufferAddress)

        // Write file data directly to VDP RAM
        for i in 0..<loadSize {
            let addr = (pab.dataBufferAddress + i) & 0x3FFF
            vdp.VDP[addr] = fileData[i]
        }

        pab.recordNumber = loadSize
        pab.charCount = 0
    }

    private func handleSave(pab: inout PAB, disk: DiskImage, drive: Int, fileName: String, vdp: TMS9918) {
        // SAVE: write VDP data as a program file
        var saveSize = pab.recordNumber
        guard saveSize > 0 else {
            pab.setError(.illegalOp)
            return
        }

        // Sanity check: don't save past end of VDP RAM (matches legacy behavior)
        if pab.dataBufferAddress + saveSize > 0x4000 {
            saveSize = 0x4000 - pab.dataBufferAddress
        }

        // Delete existing file if present
        _ = disk.deleteFile(fileName)

        // Read data from VDP
        var fileData = Data(count: saveSize)
        for i in 0..<saveSize {
            let addr = (pab.dataBufferAddress + i) & 0x3FFF
            fileData[i] = vdp.VDP[addr]
        }

        // Create FDR for program file
        var fdr = FDR()
        fdr.fileName = fileName.uppercased()
        fdr.fileType = 0x01  // Program file
        fdr.recordLength = 0
        fdr.recordsPerSector = 0
        fdr.recordCount = 0
        fdr.sectorCount = (saveSize + 255) / 256
        fdr.endOfFileOffset = saveSize % 256

        if !disk.writeFile(name: fileName, data: fileData, fdr: &fdr, isNew: true) {
            pab.setError(.deviceError)
        } else {
            disk.saveIfDirty()
        }
    }

    private func handleDelete(pab: inout PAB, disk: DiskImage, fileName: String) {
        if !disk.deleteFile(fileName) {
            pab.setError(.fileError)
        }
    }

    private func handleStatus(pab: inout PAB, disk: DiskImage, fileName: String) {
        var status: UInt8 = 0

        if let found = disk.findFile(fileName) {
            if found.fdr.isProtected { status |= 0x40 }
            if found.fdr.isInternal  { status |= 0x10 }
            if found.fdr.isProgram   { status |= 0x08 }
            if found.fdr.isVariable  { status |= 0x04 }
        } else {
            status |= 0x80  // No such file
        }

        pab.screenOffset = status
    }

    // MARK: - VDP RAM Helpers

    private func writeToVDP(vdp: TMS9918, address: Int, data: Data, offset: Int, count: Int) {
        for i in 0..<count {
            let srcIdx = offset + i
            guard srcIdx < data.count else { break }
            let vdpAddr = (address + i) & 0x3FFF
            vdp.VDP[vdpAddr] = data[srcIdx]
        }
    }

    private func readFromVDP(vdp: TMS9918, address: Int, count: Int) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let vdpAddr = (address + i) & 0x3FFF
            result.append(vdp.VDP[vdpAddr])
        }
        return result
    }

    // MARK: - File Flush

    private func flushFile(info: OpenFileInfo, disk: DiskImage, fileName: String) {
        // Delete existing file
        _ = disk.deleteFile(fileName)

        var fdr = FDR()
        fdr.fileName = fileName.uppercased()

        // Build file type byte
        var fileType: UInt8 = 0
        if info.isVariable { fileType |= 0x80 }
        if info.isInternal { fileType |= 0x02 }
        if info.isProgram  { fileType |= 0x01 }
        fdr.fileType = fileType
        fdr.recordLength = info.recordLength
        fdr.recordCount = info.recordCount

        if info.isVariable {
            fdr.recordsPerSector = 256 / (info.recordLength + 1)
        } else {
            fdr.recordsPerSector = info.recordLength > 0 ? 256 / info.recordLength : 1
        }

        _ = disk.writeFile(name: fileName, data: info.data, fdr: &fdr, isNew: true)
        disk.saveIfDirty()
    }

    // MARK: - Disk Management

    func mountDisk(drive: Int, image: DiskImage) {
        // Close any open files on this drive
        let prefix = "\(drive):"
        for key in openFiles.keys where key.hasPrefix(prefix) {
            openFiles.removeValue(forKey: key)
        }
        diskImages[drive] = image
        print("[Swift 99/a] Mounted disk in DSK\(drive): \(image.diskName) (\(image.sectorCount) sectors)")
    }

    func unmountDisk(drive: Int) {
        // Flush and close open files
        let prefix = "\(drive):"
        for (key, info) in openFiles where key.hasPrefix(prefix) {
            if info.isDirty, let disk = diskImages[drive] {
                flushFile(info: info, disk: disk, fileName: info.fileName)
            }
            openFiles.removeValue(forKey: key)
        }
        if let disk = diskImages[drive] {
            disk.saveIfDirty()
        }
        diskImages.removeValue(forKey: drive)
        print("[Swift 99/a] Unmounted DSK\(drive)")
    }
}
