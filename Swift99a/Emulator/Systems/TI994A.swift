// Swift 99/a
//
// TI994A.swift
// Concrete system assembly for the TI-99/4A home computer.
//
// This subclass of EmulatorSystem wires up all the hardware peripherals
// with the correct memory and CRU I/O address maps:
//
//   CPU Address Map:
//     0x0000–0x1FFF  Console ROM (8 KB, read-only)
//     0x2000–0x3FFF  Expansion RAM low (8 KB)
//     0x4000–0x5FFF  DSR ROM space (active when CRU-selected)
//     0x6000–0x7FFF  Cartridge ROM (8 KB, bank-switchable)
//     0x8000–0x83FF  Scratchpad RAM (256 bytes, mirrored)
//     0x8400–0x85FF  SN76489 PSG (write-only)
//     0x8800–0x8BFF  VDP read ports (data + status)
//     0x8C00–0x8FFF  VDP write ports (data + address/register)
//     0x9000–0x93FF  Speech read (status)
//     0x9400–0x97FF  Speech write (command/data)
//     0x9800–0x9BFF  GROM read ports (data + address)
//     0x9C00–0x9FFF  GROM write ports (data + address)
//     0xA000–0xFFFF  Expansion RAM high (24 KB)
//
//   CRU I/O Map:
//     Bits 0–2:    TMS9901 (interrupt control)
//     Bits 3–10:   Keyboard row read
//     Bits 18–21:  Keyboard column select + alpha lock
//     0x1100:      Disk DSR activation

import Foundation

class TI994A: EmulatorSystem {

    var pCPU: TMS9900?
    var pVDP: TMS9918?
    var pPSG: SN76489?
    var pScratch: Scratchpad?
    var pRom: ROM?
    var pGrom: GROM?
    var pKey: TIKeyboard?
    var pExpRAM: ExpansionRAM?

    // Cartridge state
    var pCartROM: CartridgeROM?
    var currentCartridge: CartridgeImage?

    // Disk controller
    var pDiskDSR: DiskDSR?

    // Speech synthesizer
    var pSpeech: TMS5220?

    // TMS9901 Programmable Systems Interface (interrupt controller / I/O)
    var pTMS9901: TMS9901?

    override init() {
        super.init()
    }

    override func initSystem() -> Bool {
        // Allocate memory and IO maps
        // CPU memory space is 64K
        memorySize = 64 * 1024
        memorySpaceRead = (0..<memorySize).map { _ in PeripheralMap() }
        memorySpaceWrite = (0..<memorySize).map { _ in PeripheralMap() }

        // IO space is CRU, 4K
        ioSize = 4 * 1024
        ioSpaceRead = (0..<ioSize).map { _ in PeripheralMap() }
        ioSpaceWrite = (0..<ioSize).map { _ in PeripheralMap() }

        // Create peripherals
        pScratch = Scratchpad(core: self)
        guard pScratch!.initialize(index: 0) else { return false }

        pPSG = SN76489(core: self)
        guard pPSG!.initialize(index: 0) else { return false }

        // 99/4A specific: ROM, GROM, VDP, Keyboard
        pRom = ROM(core: self, data: ti994AROMData)
        guard pRom!.initialize(index: 0) else { return false }

        pGrom = GROM(core: self, data: ti994AGROMData, baseAddress: 0)
        guard pGrom!.initialize(index: 0) else { return false }

        // Load Demonstration cartridge GROM at address 0x6000
        pGrom!.loadAdditionalData(demoCartGROMData, baseAddress: 0x6000)

        pVDP = TMS9918(core: self)
        guard pVDP!.initialize(index: 0) else { return false }

        pKey = TIKeyboard(core: self)
        guard pKey!.initialize(index: 0) else { return false }

        // Map memory

        // System ROM: 0x0000-0x1FFF (read only)
        for idx in 0..<0x2000 {
            _ = claimRead(sysAddr: idx, peripheral: pRom!, periphAddr: idx)
        }

        // Scratchpad RAM: 0x8000-0x83FF (256 bytes, mirrored)
        for idx in 0x8000..<0x8400 {
            _ = claimRead(sysAddr: idx, peripheral: pScratch!, periphAddr: idx & 0xFF)
            _ = claimWrite(sysAddr: idx, peripheral: pScratch!, periphAddr: idx & 0xFF)
        }

        // 32KB Memory Expansion: 0x2000-0x3FFF (8KB) + 0xA000-0xFFFF (24KB)
        pExpRAM = ExpansionRAM(core: self)
        guard pExpRAM!.initialize(index: 0) else { return false }

        // Low 8KB: 0x2000-0x3FFF → RAM offset 0x0000-0x1FFF
        for idx in 0x2000..<0x4000 {
            _ = claimRead(sysAddr: idx, peripheral: pExpRAM!, periphAddr: idx - 0x2000)
            _ = claimWrite(sysAddr: idx, peripheral: pExpRAM!, periphAddr: idx - 0x2000)
        }
        // High 24KB: 0xA000-0xFFFF → RAM offset 0x2000-0x7FFF
        for idx in 0xA000..<0x10000 {
            _ = claimRead(sysAddr: idx, peripheral: pExpRAM!, periphAddr: (idx - 0xA000) + 0x2000)
            _ = claimWrite(sysAddr: idx, peripheral: pExpRAM!, periphAddr: (idx - 0xA000) + 0x2000)
        }

        // VDP read ports: 0x8800-0x8BFF (even addresses)
        for idx in stride(from: 0x8800, to: 0x8C00, by: 2) {
            _ = claimRead(sysAddr: idx, peripheral: pVDP!, periphAddr: (idx & 2) != 0 ? 1 : 0)
        }

        // VDP write ports: 0x8C00-0x8FFF (even addresses)
        for idx in stride(from: 0x8C00, to: 0x9000, by: 2) {
            _ = claimWrite(sysAddr: idx, peripheral: pVDP!, periphAddr: (idx & 2) != 0 ? 1 : 0)
        }

        // PSG write port: 0x8400-0x85FE (even addresses, write only)
        for idx in stride(from: 0x8400, to: 0x8600, by: 2) {
            _ = claimWrite(sysAddr: idx, peripheral: pPSG!, periphAddr: 0)
        }

        // GROM read ports: 0x9800-0x9BFF (even addresses)
        for idx in stride(from: 0x9800, to: 0x9C00, by: 2) {
            let addr = (idx & 2) != 0 ? GROM.MODE_ADDRESS : 0
            _ = claimRead(sysAddr: idx, peripheral: pGrom!, periphAddr: addr)
        }

        // GROM write ports: 0x9C00-0x9FFF (even addresses)
        for idx in stride(from: 0x9C00, to: 0xA000, by: 2) {
            let addr: Int
            if (idx & 2) != 0 {
                addr = GROM.MODE_ADDRESS | GROM.MODE_WRITE
            } else {
                addr = GROM.MODE_WRITE
            }
            _ = claimWrite(sysAddr: idx, peripheral: pGrom!, periphAddr: addr)
        }

        // Wait states: everything outside scratchpad and ROM gets 2 wait states per byte
        for idx in 0x2000..<0x8000 {
            memorySpaceRead[idx].updateMap(who: nil, addr: -1, waitStates: 2)
            memorySpaceWrite[idx].updateMap(who: nil, addr: -1, waitStates: 2)
        }
        for idx in 0x8400..<0x10000 {
            memorySpaceRead[idx].updateMap(who: nil, addr: -1, waitStates: 2)
            memorySpaceWrite[idx].updateMap(who: nil, addr: -1, waitStates: 2)
        }

        // TMS9901 Programmable Systems Interface
        // Handles interrupt inputs (CRU bits 0-2) and timer.
        // Bit 2 reflects VDP INT* status — critical for the console ROM ISR
        // to take the correct VDP interrupt handling path.
        pTMS9901 = TMS9901(core: self)
        guard pTMS9901!.initialize(index: 0) else { return false }
        pTMS9901!.vdp = pVDP

        // Map TMS9901 CRU bits 0-2 for read and write
        // These are mirrored every 32 bits through the 0x000-0x7FF range
        // (the console ROM accesses them with R12=0, so CRU base = 0)
        for idx in stride(from: 0, to: 0x800, by: 32) {
            for off in 0...2 {
                _ = claimIORead(sysAddr: idx + off, peripheral: pTMS9901!, periphAddr: off)
                _ = claimIOWrite(sysAddr: idx + off, peripheral: pTMS9901!, periphAddr: off)
            }
        }

        // Keyboard CRU I/O
        for idx in stride(from: 0, to: 0x800, by: 20) {
            for off in 3...10 {
                _ = claimIORead(sysAddr: idx + off, peripheral: pKey!, periphAddr: off)
            }
            for off in 18...20 {
                _ = claimIOWrite(sysAddr: idx + off, peripheral: pKey!, periphAddr: off)
            }
            // Alpha lock on bit 21
            _ = claimIOWrite(sysAddr: idx + 21, peripheral: pKey!, periphAddr: 21)
            // Bit 17 read (9901 timer related)
            _ = claimIORead(sysAddr: idx + 17, peripheral: pKey!, periphAddr: 17)
        }

        // Speech synthesizer: read 0x9000-0x93FF, write 0x9400-0x97FF (even addresses)
        pSpeech = TMS5220(core: self)
        guard pSpeech!.initialize(index: 0) else { return false }

        for idx in stride(from: 0x9000, to: 0x9400, by: 2) {
            _ = claimRead(sysAddr: idx, peripheral: pSpeech!, periphAddr: 0)
        }
        for idx in stride(from: 0x9400, to: 0x9800, by: 2) {
            _ = claimWrite(sysAddr: idx, peripheral: pSpeech!, periphAddr: 0)
        }

        // Disk controller DSR
        pDiskDSR = DiskDSR(core: self)
        guard pDiskDSR!.initialize(index: 0) else { return false }
        pDiskDSR!.vdp = pVDP

        // Map DSR ROM space: 0x4000-0x5FFF (active only when CRU 0x1100 selects it)
        for idx in 0x4000..<0x6000 {
            _ = claimRead(sysAddr: idx, peripheral: pDiskDSR!, periphAddr: idx - 0x4000)
            _ = claimWrite(sysAddr: idx, peripheral: pDiskDSR!, periphAddr: idx - 0x4000)
        }

        // Map CRU for disk controller at base 0x1100
        // CRU bit 0 (address 0x1100/2 = 0x880 in CRU space) activates DSR
        let cruBase = 0x1100 / 2  // CRU addresses are bit-addressed, divided by 2 for byte map
        _ = claimIORead(sysAddr: cruBase, peripheral: pDiskDSR!, periphAddr: 0)
        _ = claimIOWrite(sysAddr: cruBase, peripheral: pDiskDSR!, periphAddr: 0)

        // Register PC interceptor for DSR entry at 0x4800
        pcInterceptors[0x4800] = { [weak self] cpu in
            guard let self = self, let dsr = self.pDiskDSR else { return false }
            return dsr.handleDSREntry(cpu: cpu)
        }

        // Register PC interceptor for FILES subprogram entry at 0x4880
        pcInterceptors[0x4880] = { [weak self] cpu in
            guard let self = self, let dsr = self.pDiskDSR else { return false }
            return dsr.handleFilesSubprogram(cpu: cpu)
        }

        // CPU must be created last (needs memory map active for reset)
        pCPU = TMS9900(core: self)
        guard pCPU!.initialize(index: 0) else { return false }

        // Audio engine (display buffer is set by Emulator)
        audioEngine = AudioEngine()

        return true
    }

    override func deInitSystem() -> Bool {
        _ = pCPU?.cleanup()
        _ = pVDP?.cleanup()
        _ = pPSG?.cleanup()
        _ = pScratch?.cleanup()
        _ = pRom?.cleanup()
        _ = pGrom?.cleanup()
        _ = pKey?.cleanup()
        _ = pExpRAM?.cleanup()
        _ = pCartROM?.cleanup()
        _ = pDiskDSR?.cleanup()
        _ = pSpeech?.cleanup()
        _ = pTMS9901?.cleanup()

        pCPU = nil
        pVDP = nil
        pPSG = nil
        pScratch = nil
        pRom = nil
        pGrom = nil
        pKey = nil
        pExpRAM = nil
        pCartROM = nil
        currentCartridge = nil
        pDiskDSR = nil
        pSpeech = nil
        pTMS9901 = nil

        memorySpaceRead = []
        memorySpaceWrite = []
        ioSpaceRead = []
        ioSpaceWrite = []
        memorySize = 0
        ioSize = 0

        return true
    }

    override func runSystem(microSeconds: Int) -> Bool {
        currentTimestamp += Double(microSeconds)

        // Run CPU and VDP
        _ = pCPU?.operate(timestamp: currentTimestamp)
        _ = pVDP?.operate(timestamp: currentTimestamp)

        // Run speech synthesis in sync with CPU timing.
        // This generates 8kHz samples into a ring buffer that the audio
        // callback reads from.  Running it here (after the CPU) ensures
        // that FIFO writes from the CPU are visible to the synthesizer
        // before it tries to consume them.
        _ = pSpeech?.operate(timestamp: currentTimestamp)

        // Route VDP interrupt to CPU (level 1)
        if let vdp = pVDP, vdp.isIntActive() {
            requestInt(level: 1)
        } else {
            clearInt(level: 1)
        }

        // Notify memory map visualization (CPU-sync mode)
        memoryMapCallback?()

        return true
    }

    // MARK: - Cartridge Management

    /// Insert a cartridge image into the system, mapping ROM and/or GROM data
    func insertCartridge(_ image: CartridgeImage) {
        // Remove any existing cartridge first
        removeCartridge()

        // Always clear cartridge GROM space before loading new data,
        // even if no cartridge was previously inserted (e.g., demo cart
        // GROM loaded during initSystem needs to be cleared)
        GROM.clearCartridgeGROM()

        currentCartridge = image

        // Load GROM data if present
        if let gromData = image.gromData {
            pGrom?.loadAdditionalData([UInt8](gromData), baseAddress: 0x6000)
        }

        // Map CPU ROM if present
        if image.romData != nil {
            let cartROM = CartridgeROM(core: self, image: image)
            guard cartROM.initialize(index: 0) else { return }
            pCartROM = cartROM

            // Map cartridge ROM at 0x6000-0x7FFF
            for idx in 0x6000..<0x8000 {
                _ = claimRead(sysAddr: idx, peripheral: cartROM, periphAddr: idx - 0x6000)
                _ = claimWrite(sysAddr: idx, peripheral: cartROM, periphAddr: idx - 0x6000)
            }
        }

        // Reset CPU to restart from title screen
        pCPU?.reset()
    }

    /// Remove the current cartridge, unmapping its ROM and clearing cart GROM space
    func removeCartridge() {
        guard currentCartridge != nil else { return }

        // Unmap cartridge ROM space (restore to DummyPeripheral)
        if pCartROM != nil {
            for idx in 0x6000..<0x8000 {
                memorySpaceRead[idx] = PeripheralMap()
                memorySpaceWrite[idx] = PeripheralMap()
            }
            // Restore wait states for this region
            for idx in 0x6000..<0x8000 {
                memorySpaceRead[idx].updateMap(who: nil, addr: -1, waitStates: 2)
                memorySpaceWrite[idx].updateMap(who: nil, addr: -1, waitStates: 2)
            }
            _ = pCartROM?.cleanup()
            pCartROM = nil
        }

        // Clear cartridge GROM area (0x6000+), preserving console GROMs
        GROM.clearCartridgeGROM()

        currentCartridge = nil

        // Reset CPU to go back to title screen
        pCPU?.reset()
    }
}
