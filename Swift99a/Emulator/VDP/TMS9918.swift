// Swift 99/a
//
// TMS9918.swift
// Emulation of the Texas Instruments TMS9918A Video Display Processor.
//
// The TMS9918A provides:
//   - 16 KB of dedicated VRAM (not CPU-addressable; accessed via I/O ports)
//   - 8 control registers (write-only) and 1 status register (read-only)
//   - Multiple display modes: Graphics I, Graphics II (Bitmap), Text (40-col),
//     Multicolor, and their Bitmap variants
//   - 32 hardware sprites with collision detection and 5th-sprite-on-line flag
//   - NTSC timing: 262 scanlines/frame at 60 Hz, 192 active display lines
//   - Vertical interrupt (active-low INT* pin) triggered at end of active display
//
// The VDP port interface uses two addresses:
//   addr=0: VRAM data read/write (with prefetch mechanism)
//   addr=1: Status register read / address+register write (two-byte sequence)
//
// This file contains the VDP state, I/O handling, and frame push logic.
// Rendering is in TMS9918+Rendering.swift.

import Foundation
import CoreGraphics

// MARK: - TMS9918A Standard Color Palette
// Native UInt32 in ARGB format (0xAARRGGBB) for macOS little-endian pixel buffers.
// Used with CGBitmapInfo: premultipliedFirst | byteOrder32Little.
let tmsPalette: [UInt32] = [
    0x00000000,  //  0 Transparent
    0xFF000000,  //  1 Black
    0xFF21C842,  //  2 Medium Green
    0xFF5EDC78,  //  3 Light Green
    0xFF5455ED,  //  4 Dark Blue
    0xFF7D76FC,  //  5 Light Blue
    0xFFD4524D,  //  6 Dark Red
    0xFF42EBF5,  //  7 Cyan
    0xFFFC5554,  //  8 Medium Red
    0xFFFF7978,  //  9 Light Red
    0xFFD4C154,  // 10 Dark Yellow
    0xFFE6CE80,  // 11 Light Yellow
    0xFF21B03B,  // 12 Dark Green
    0xFFC95BBA,  // 13 Magenta
    0xFFCCCCCC,  // 14 Gray
    0xFFFFFFFF   // 15 White
]

final class TMS9918: Peripheral {

    /// VDP port reads have side effects (status read clears latched bits)
    /// and computed return values, so they cannot be served from shadow.
    override var readsHaveSideEffects: Bool { true }


    // MARK: - VRAM and Registers

    /// 16 KB of Video RAM (not directly CPU-addressable)
    var VDP = [UInt8](repeating: 0, count: 16 * 1024)

    /// VDP control registers R0–R7 (write-only on real hardware).
    /// Indices 8–15 are reserved/unused but allocated for future compatibility.
    var VDPREG = [Int](repeating: 0, count: 16)
    var VDPS: Int = 0       // Status register (INT, 5SPR, SCOL, 5th sprite number)
    var VDPADD: Int = 0     // 14-bit VRAM address counter

    // MARK: - Derived Table Addresses (computed from registers by getTables())
    var SIT: Int = 0        // Screen Image Table
    var CT: Int = 0         // Color Table
    var PDT: Int = 0        // Pattern Descriptor Table
    var SAL: Int = 0        // Sprite Attribute List
    var SDT: Int = 0        // Sprite Descriptor Table
    var CTsize: Int = 0     // Color table size mask (bitmap modes)
    var PDTsize: Int = 0    // Pattern table size mask (bitmap modes)

    // MARK: - Internal Timing State
    var vdpaccess: Int = 0      // Two-byte write sequence state (0 or 1)
    var vdpscanline: Int = 0    // Current scanline being processed
    var vdpprefetch: Int = 0    // Prefetched byte for data reads
    var hzRate: Int = 60        // Frame rate (NTSC = 60, PAL = 50)
    var redraw_needed: Int = 262 // Scanlines remaining that need redraw

    /// True when VDP register writes have invalidated the cached derived
    /// table addresses (SIT/CT/PDT/SAL/SDT). Set by `wVDPreg`, cleared by
    /// `getTables()`. Avoids redundant register-bit recomputation 15 720× per
    /// second when no register has actually changed mid-frame.
    var tablesDirty: Bool = true

    // MARK: - Sprite Collision Detection
    var sprColBuf = [UInt8](repeating: 0, count: 256) // Per-pixel collision buffer (one scanline)
    var sprColFlag: Int = 0                            // Non-zero if collision detected this line

    // Frame counter for diagnostics
    var frameCount: Int = 0

    // MARK: - Frame Buffer
    /// Pixel buffer for current frame (TMS_WIDTH × TMS_HEIGHT, ARGB UInt32).
    /// Backed by an `UnsafeMutablePointer` (allocated once, freed in `deinit`)
    /// rather than a Swift `[UInt32]` so the per-pixel render writes skip the
    /// array bounds check — ~50K writes per frame at 60 fps.
    private let frameBufferStorage: UnsafeMutablePointer<UInt32>
    let frameBuffer: UnsafeMutableBufferPointer<UInt32>
    let fbWidth = TMS_WIDTH
    let fbHeight = TMS_HEIGHT

    // MARK: - Status Register Flag Constants
    let VDPS_INT: Int  = 0x80   // Vertical interrupt pending
    let VDPS_5SPR: Int = 0x40   // 5th sprite on a scanline detected
    let VDPS_SCOL: Int = 0x20   // Sprite collision detected

    init(core: EmulatorSystem) {
        let pixelCount = TMS_WIDTH * TMS_HEIGHT
        let storage = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        storage.initialize(repeating: 0, count: pixelCount)
        self.frameBufferStorage = storage
        self.frameBuffer = UnsafeMutableBufferPointer(start: storage, count: pixelCount)
        super.init(core: core)
    }

    isolated deinit {
        frameBufferStorage.deinitialize(count: fbWidth * fbHeight)
        frameBufferStorage.deallocate()
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TMS9918", index: index)
        vdpReset(cold: true)
        return true
    }

    override func cleanup() -> Bool { return true }

    /// Returns true if the VDP interrupt is active AND enabled (R1 bit 5).
    /// The TMS9901 checks this to decide whether to assert level-1 to the CPU.
    func isIntActive() -> Bool {
        return (VDPS & VDPS_INT) != 0 && (VDPREG[1] & 0x20) != 0
    }

    // MARK: - Read/Write

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        if accessType == .free {
            return VDP[addr & 0x3FFF]
        }

        if addr != 0 {
            // Read status register
            let ret = UInt8(VDPS)
            VDPS &= 0x1F       // clear top flags on read
            vdpaccess = 0
            // Immediately clear the level-1 interrupt request in the system
            // so the CPU won't re-enter the ISR on stale state within the
            // same operate() batch.  On real hardware the VDP releases the
            // INT* pin as soon as the status register is read, and the
            // TMS9901 would see it go high before the next instruction.
            theCore?.clearInt(level: 1)
            return ret
        } else {
            // Read data
            vdpaccess = 0
            let ret = UInt8(vdpprefetch)
            let realVDP = getRealVDP()
            vdpprefetch = Int(VDP[realVDP])
            incrementVDPAdd()
            return ret
        }
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        if accessType == .free {
            VDP[addr & 0x3FFF] = data
            return
        }

        if addr != 0 {
            // Write address/register
            if vdpaccess == 0 {
                VDPADD = (VDPADD & 0xFF00) | Int(data)
                vdpaccess = 1
            } else {
                VDPADD = (VDPADD & 0x00FF) | (Int(data) << 8)
                vdpaccess = 0

                if VDPADD & 0x8000 != 0 {
                    // Register write
                    let nReg = (VDPADD & 0x3F00) >> 8
                    let nData = VDPADD & 0xFF
                    wVDPreg(UInt8(nReg & 0x07), UInt8(nData))
                    redraw_needed = 262
                }

                if (VDPADD & 0xC000) == 0 {
                    // Prefetch on address set
                    let realVDP = getRealVDP()
                    vdpprefetch = Int(VDP[realVDP])
                    incrementVDPAdd()
                } else {
                    VDPADD &= 0x3FFF
                }
            }
        } else {
            // Write data
            vdpaccess = 0
            let realVDP = getRealVDP()
            VDP[realVDP] = data
            vdpprefetch = Int(data)
            incrementVDPAdd()
            redraw_needed = 262
        }
    }

    // MARK: - Operate (scanline timing)

    override func operate(timestamp: Double) -> Bool {
        if lastTimestamp == 0 || timestamp < lastTimestamp {
            lastTimestamp = timestamp
            return true
        }

        let timePerScanline = 1_000_000.0 / Double(hzRate * 262)

        while lastTimestamp + timePerScanline < timestamp {
            vdpscanline += 1

            if vdpscanline == TMS_DISPLAY_HEIGHT + TMS_FIRST_DISPLAY_LINE {
                // Set vertical interrupt
                VDPS |= VDPS_INT
            } else if vdpscanline == TMS_HEIGHT {
                // Frame complete - push to display
                pushFrame()
            } else if vdpscanline >= TMS_HEIGHT + TMS_BLANKING {
                vdpscanline = 0
            }

            // Render this scanline
            vdpDisplay(scanline: vdpscanline)

            lastTimestamp += timePerScanline
        }

        return true
    }

    // MARK: - Internal Helpers

    /// Auto-increment the 14-bit VRAM address counter (wraps at 16 KB boundary).
    func incrementVDPAdd() {
        VDPADD = (VDPADD + 1) & 0x3FFF
    }

    /// Map the logical VRAM address to the physical address, accounting for
    /// 4K/16K mode address mangling (controlled by R1 bit 7).
    func getRealVDP() -> Int {
        if VDPREG[1] & 0x80 != 0 {
            return VDPADD & 0x3FFF
        } else {
            // 4K mode address mangling
            return (VDPADD & 0x203F) | ((VDPADD & 0x0FC0) << 1) | ((VDPADD & 0x1000) >> 7)
        }
    }

    /// Write to a VDP register (R0–R7). Forces full-frame redraw on any change.
    func wVDPreg(_ r: UInt8, _ v: UInt8) {
        guard r < 8 else { return }
        VDPREG[Int(r)] = Int(v)
        redraw_needed = 262
        tablesDirty = true
    }

    /// Recompute derived table addresses from the current VDP register values.
    /// Called at the start of each scanline to pick up mid-frame register changes.
    func getTables() {
        SIT = (VDPREG[2] & 0x0F) << 10
        SAL = (VDPREG[5] & 0x7F) << 7
        SDT = (VDPREG[6] & 0x07) << 11

        if VDPREG[0] & 0x02 != 0 {
            // Bitmap mode
            CT = (VDPREG[3] & 0x80) != 0 ? 0x2000 : 0
            CTsize = ((VDPREG[3] & 0x7F) << 6) | 0x3F
            PDT = (VDPREG[4] & 0x04) != 0 ? 0x2000 : 0
            PDTsize = (VDPREG[4] & 0x03) << 11
            if VDPREG[1] & 0x10 != 0 {
                PDTsize |= 0x7FF
            } else {
                PDTsize |= (CTsize & 0x7FF)
            }
        } else {
            // Non-bitmap modes
            CT = VDPREG[3] << 6
            PDT = (VDPREG[4] & 0x07) << 11
            CTsize = 32
            PDTsize = 2048
        }
    }

    func vdpReset(cold: Bool) {
        if cold {
            VDPREG = [Int](repeating: 0, count: 16)
            VDP = [UInt8](repeating: 0, count: 16 * 1024)
        }
        vdpaccess = 0
        vdpscanline = 0
        vdpprefetch = 0
        redraw_needed = 262
    }

    /// Convert the frame buffer to a CGImage and push it to the display system.
    func pushFrame() {
        guard let display = theCore?.displayBuffer else { return }
        frameCount += 1

        // Create CGImage from our ARGB frame buffer
        let width = fbWidth
        let height = fbHeight
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)

        guard let context = CGContext(
            data: frameBufferStorage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return }

        if let image = context.makeImage() {
            display.updateFrame(image)
        }
    }

    /// Look up the ARGB color for a palette index. Index 0 (transparent)
    /// maps to the backdrop color (VDP register 7, low nibble).
    func colorForIndex(_ idx: Int) -> UInt32 {
        if idx == 0 {
            // Transparent - use backdrop color
            return tmsPalette[VDPREG[7] & 0x0F]
        }
        return tmsPalette[idx & 0x0F]
    }
}
