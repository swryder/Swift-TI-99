// Swift 99/a
//
// TMS9918+Rendering.swift
// Scanline-based rendering for all TMS9918A display modes and sprites.
//
// The TMS9918A supports the following modes (selected by register bits):
//   - Graphics I:         32×24 characters, 8×8 patterns, 1-of-8 color groups
//   - Graphics II:        32×24 characters with per-row color (bitmap mode)
//   - Text:               40×24 characters, 6-pixel wide, no sprites
//   - Bitmap Text:        40×24 with bitmap pattern addressing
//   - Multicolor:         64×48 blocks of 4×4 color cells
//   - Bitmap Multicolor:  Multicolor with bitmap pattern addressing
//   - Illegal:            Mode bits 1+2 both set — displays colored bars
//
// Sprites (all non-text modes):
//   - 32 sprites, max 4 visible per scanline (5th triggers status flag)
//   - 8×8 or 16×16 patterns, optional 2× magnification
//   - Per-sprite early clock, collision detection, transparent color 0

import Foundation

// MARK: - Display Timing Constants
let TMS_WIDTH = 284
let TMS_HEIGHT = 243
let TMS_BLANKING = 19

let TMS_DISPLAY_HEIGHT = 192
let TMS_DISPLAY_WIDTH = 256
let TMS_DISPLAY_TEXT = 240

let TMS_FIRST_DISPLAY_LINE = 27
let TMS_FIRST_DISPLAY_PIXEL = 13
let TMS_FIRST_DISPLAY_TEXT = 19

extension TMS9918 {

    // MARK: - Main display dispatch

    func vdpDisplay(scanline: Int) {
        if tablesDirty {
            getTables()
            tablesDirty = false
        }

        let gfxline = scanline - TMS_FIRST_DISPLAY_LINE
        guard gfxline >= 0 && gfxline < TMS_DISPLAY_HEIGHT else { return }

        // Calculate line offset in frame buffer
        let lineOffset = scanline * fbWidth

        // Blank the entire line with backdrop color
        let backdrop = colorForIndex(VDPREG[7] & 0x0F)
        for x in 0..<fbWidth {
            frameBuffer[lineOffset + x] = backdrop
        }

        // Check if display is enabled
        guard (VDPREG[1] & 0x40) != 0 else {
            // Display blanked - still draw sprites if not text mode
            if (VDPREG[1] & 0x10) == 0 {
                drawSprites(scanline: gfxline, lineOffset: lineOffset)
            }
            return
        }

        // Determine mode and render
        let reg0 = VDPREG[0]

        if (VDPREG[1] & 0x18) == 0x18 {
            // Illegal mode (mode bits 1+2 both set)
            vdpIllegal(scanline: gfxline, lineOffset: lineOffset)
        } else if (VDPREG[1] & 0x10) != 0 {
            // Mode bit 2 set - text modes
            if (reg0 & 0x02) != 0 {
                vdpTextII(scanline: gfxline, lineOffset: lineOffset)
            } else {
                vdpText(scanline: gfxline, lineOffset: lineOffset)
            }
        } else if (VDPREG[1] & 0x08) != 0 {
            // Mode bit 1 - multicolor modes
            if (reg0 & 0x02) != 0 {
                vdpMulticolorII(scanline: gfxline, lineOffset: lineOffset)
            } else {
                vdpMulticolor(scanline: gfxline, lineOffset: lineOffset)
            }
        } else if (reg0 & 0x02) != 0 {
            // Bitmap mode
            vdpGraphicsII(scanline: gfxline, lineOffset: lineOffset)
        } else {
            // Standard graphics mode
            vdpGraphics(scanline: gfxline, lineOffset: lineOffset)
        }
    }

    // MARK: - Graphics I Mode (32x24 characters, 8x8 patterns)

    func vdpGraphics(scanline: Int, lineOffset: Int) {
        let i3 = scanline & 0x07
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_PIXEL
        var o = (scanline / 8) * 32

        for _ in stride(from: 0, to: 256, by: 8) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (ch << 3) + i3
            let c = ch >> 3
            let colorByte = Int(VDP[CT + c])
            let fgc = colorByte >> 4
            let bgc = colorByte & 0x0F
            o += 1

            let t = Int(VDP[p_add])
            let fgColor = colorForIndex(fgc)
            let bgColor = colorForIndex(bgc)

            frameBuffer[pIdx]     = (t & 0x80) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 1] = (t & 0x40) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 2] = (t & 0x20) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 3] = (t & 0x10) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 4] = (t & 0x08) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 5] = (t & 0x04) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 6] = (t & 0x02) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 7] = (t & 0x01) != 0 ? fgColor : bgColor
            pIdx += 8
        }

        drawSprites(scanline: scanline, lineOffset: lineOffset)
    }

    // MARK: - Graphics II / Bitmap Mode

    func vdpGraphicsII(scanline: Int, lineOffset: Int) {
        let i1 = scanline & 0xF8
        let i3 = scanline & 0x07
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_PIXEL
        var o = (scanline / 8) * 32

        let table = i1 / 64
        let Poffset = table * 0x800
        let Coffset = table * 0x800

        for _ in stride(from: 0, to: 256, by: 8) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (((ch << 3) + Poffset) & PDTsize) + i3
            let c_add = CT + (((ch << 3) + Coffset) & CTsize) + i3
            o += 1

            let t = Int(VDP[p_add])
            let colorByte = Int(VDP[c_add])
            let fgc = colorByte >> 4
            let bgc = colorByte & 0x0F

            let fgColor = colorForIndex(fgc)
            let bgColor = colorForIndex(bgc)

            frameBuffer[pIdx]     = (t & 0x80) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 1] = (t & 0x40) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 2] = (t & 0x20) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 3] = (t & 0x10) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 4] = (t & 0x08) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 5] = (t & 0x04) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 6] = (t & 0x02) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 7] = (t & 0x01) != 0 ? fgColor : bgColor
            pIdx += 8
        }

        drawSprites(scanline: scanline, lineOffset: lineOffset)
    }

    // MARK: - Text Mode (40 columns, 6-pixel wide characters)

    func vdpText(scanline: Int, lineOffset: Int) {
        let i3 = scanline & 0x07
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_TEXT
        var o = (scanline / 8) * 40

        let colorReg = VDPREG[7]
        let fgc = colorReg >> 4
        let bgc = colorReg & 0x0F
        let fgColor = colorForIndex(fgc)
        let bgColor = colorForIndex(bgc)

        for _ in stride(from: 8, to: 248, by: 6) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (ch << 3) + i3
            o += 1

            let t = Int(VDP[p_add])

            // 6 pixels wide (top 6 bits of pattern byte)
            frameBuffer[pIdx]     = (t & 0x80) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 1] = (t & 0x40) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 2] = (t & 0x20) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 3] = (t & 0x10) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 4] = (t & 0x08) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 5] = (t & 0x04) != 0 ? fgColor : bgColor
            pIdx += 6
        }

        // No sprites in text mode
    }

    // MARK: - Bitmap Text Mode

    func vdpTextII(scanline: Int, lineOffset: Int) {
        let i1 = scanline & 0xF8
        let i3 = scanline & 0x07
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_TEXT
        var o = (scanline / 8) * 40

        let colorReg = VDPREG[7]
        let fgc = colorReg >> 4
        let bgc = colorReg & 0x0F
        let fgColor = colorForIndex(fgc)
        let bgColor = colorForIndex(bgc)

        let table = i1 / 64
        let Poffset = table * 0x800

        for _ in stride(from: 8, to: 248, by: 6) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (((ch << 3) + Poffset) & PDTsize) + i3
            o += 1

            let t = Int(VDP[p_add])

            frameBuffer[pIdx]     = (t & 0x80) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 1] = (t & 0x40) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 2] = (t & 0x20) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 3] = (t & 0x10) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 4] = (t & 0x08) != 0 ? fgColor : bgColor
            frameBuffer[pIdx + 5] = (t & 0x04) != 0 ? fgColor : bgColor
            pIdx += 6
        }

        // No sprites in text mode
    }

    // MARK: - Illegal Mode (mode bits 1+2 set)

    func vdpIllegal(scanline: Int, lineOffset: Int) {
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_TEXT

        let colorReg = VDPREG[7]
        let fgc = colorReg >> 4
        let bgc = colorReg & 0x0F
        let fgColor = colorForIndex(fgc)
        let bgColor = colorForIndex(bgc)

        // Each "character" is 4 pixels foreground + 2 pixels background
        for _ in stride(from: 8, to: 248, by: 6) {
            frameBuffer[pIdx]     = fgColor
            frameBuffer[pIdx + 1] = fgColor
            frameBuffer[pIdx + 2] = fgColor
            frameBuffer[pIdx + 3] = fgColor
            frameBuffer[pIdx + 4] = bgColor
            frameBuffer[pIdx + 5] = bgColor
            pIdx += 6
        }

        // No sprites in illegal mode
    }

    // MARK: - Multicolor Mode (4x4 color blocks)

    func vdpMulticolor(scanline: Int, lineOffset: Int) {
        let i3 = scanline & 0x04
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_PIXEL
        var o = (scanline / 8) * 32
        let off = (scanline >> 2) & 0x06

        for _ in stride(from: 0, to: 256, by: 8) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (ch << 3) + off + (i3 >> 2)
            o += 1

            let colorByte = Int(VDP[p_add])
            let fgc = colorByte >> 4
            let bgc = colorByte & 0x0F
            let fgColor = colorForIndex(fgc)
            let bgColor = colorForIndex(bgc)

            // 4 pixels foreground, 4 pixels background
            frameBuffer[pIdx]     = fgColor
            frameBuffer[pIdx + 1] = fgColor
            frameBuffer[pIdx + 2] = fgColor
            frameBuffer[pIdx + 3] = fgColor
            frameBuffer[pIdx + 4] = bgColor
            frameBuffer[pIdx + 5] = bgColor
            frameBuffer[pIdx + 6] = bgColor
            frameBuffer[pIdx + 7] = bgColor
            pIdx += 8
        }

        drawSprites(scanline: scanline, lineOffset: lineOffset)
    }

    // MARK: - Bitmap Multicolor Mode

    func vdpMulticolorII(scanline: Int, lineOffset: Int) {
        let i1 = scanline & 0xF8
        let i3 = scanline & 0x04
        var pIdx = lineOffset + TMS_FIRST_DISPLAY_PIXEL
        var o = (scanline / 8) * 32

        let table = i1 / 64
        let Poffset = table * 0x800

        for _ in stride(from: 0, to: 256, by: 8) {
            let ch = Int(VDP[SIT + o])
            let p_add = PDT + (((ch << 3) + Poffset) & PDTsize) + i3
            o += 1

            let colorByte = Int(VDP[p_add])
            let fgc = colorByte >> 4
            let bgc = colorByte & 0x0F
            let fgColor = colorForIndex(fgc)
            let bgColor = colorForIndex(bgc)

            frameBuffer[pIdx]     = fgColor
            frameBuffer[pIdx + 1] = fgColor
            frameBuffer[pIdx + 2] = fgColor
            frameBuffer[pIdx + 3] = fgColor
            frameBuffer[pIdx + 4] = bgColor
            frameBuffer[pIdx + 5] = bgColor
            frameBuffer[pIdx + 6] = bgColor
            frameBuffer[pIdx + 7] = bgColor
            pIdx += 8
        }

        drawSprites(scanline: scanline, lineOffset: lineOffset)
    }

    // MARK: - Sprite Rendering

    func drawSprites(scanline: Int, lineOffset: Int) {
        // Fifth sprite tracking
        var b5OnLine: Int = -1

        // Check if 5-on-line already latched
        if (VDPS & VDPS_5SPR) != 0 {
            b5OnLine = VDPS & 0x1F
        }

        // Clear collision buffer for this line
        for i in 0..<256 { sprColBuf[i] = 0 }
        sprColFlag = 0

        let highest = 31

        // Calculate sprite height
        var height = 8
        if (VDPREG[1] & 0x01) != 0 { height *= 2 }   // magnified
        if (VDPREG[1] & 0x02) != 0 { height *= 2 }   // double size

        let max = 5  // 9918A fifth sprite limit

        // Build list of sprites on this scanline
        var sprList = [Int]()
        sprList.reserveCapacity(max)

        for i1 in 0...highest {
            let adr = SAL + (i1 << 2)
            let yByte = Int(VDP[adr])
            if yByte == 0xD0 { break }   // end-of-sprites marker

            var yy = yByte + 1
            if yy > 225 { yy -= 256 }

            if scanline >= yy && scanline < yy + height {
                sprList.append(adr)
                if sprList.count >= max {
                    if b5OnLine == -1 { b5OnLine = i1 }
                    break
                }
            }
        }

        // Draw sprites in reverse order (lowest numbered on top)
        let mag = (VDPREG[1] & 0x01) != 0
        let dblSize = (VDPREG[1] & 0x02) != 0

        for idx in stride(from: sprList.count - 1, through: 0, by: -1) {
            var curSAL = sprList[idx]
            var yy = Int(VDP[curSAL]) + 1
            if yy > 225 { yy -= 256 }
            curSAL += 1

            var xx = Int(VDP[curSAL])
            curSAL += 1

            var pat = Int(VDP[curSAL])
            curSAL += 1

            if dblSize {
                pat = pat & 0xFC
            }

            let attrib = Int(VDP[curSAL])
            let colIdx = attrib & 0x0F
            let sprColor: UInt32 = colIdx == 0 ? 0 : tmsPalette[colIdx]

            if (attrib & 0x80) != 0 {
                xx -= 32   // early clock
            }

            // Work out which line of the sprite to draw
            var spriteline = scanline - yy
            if mag { spriteline /= 2 }
            if spriteline > 7 {
                spriteline -= 8
                pat += 1
            }

            var p_add = SDT + (pat << 3) + (spriteline % 8)
            let pBase = lineOffset + TMS_FIRST_DISPLAY_PIXEL

            let charCount = dblSize ? 2 : 1
            for _ in 0..<charCount {
                var mask = 0x80
                let p = Int(VDP[p_add])

                for _ in 0..<8 {
                    if xx >= 0 && xx <= 255 {
                        if mag {
                            if (p & mask) != 0 {
                                // Collision detection
                                sprColFlag |= Int(sprColBuf[xx])
                                sprColBuf[xx] = 1
                                if xx < 255 {
                                    sprColFlag |= Int(sprColBuf[xx + 1])
                                    sprColBuf[xx + 1] = 1
                                }

                                // Render (skip transparent sprites)
                                if colIdx != 0 {
                                    frameBuffer[pBase + xx] = sprColor
                                    if xx < 255 {
                                        frameBuffer[pBase + xx + 1] = sprColor
                                    }
                                }
                            }
                        } else {
                            if (p & mask) != 0 {
                                sprColFlag |= Int(sprColBuf[xx])
                                sprColBuf[xx] = 1

                                if colIdx != 0 {
                                    frameBuffer[pBase + xx] = sprColor
                                }
                            }
                        }
                    }

                    if mag {
                        xx += 2
                    } else {
                        xx += 1
                    }
                    mask >>= 1
                }

                // Second character in double-size sprite mode
                p_add += 16
            }
        }

        // Update VDP status register
        if sprColFlag != 0 {
            VDPS |= VDPS_SCOL
        }
        if b5OnLine != -1 {
            VDPS &= (VDPS_INT | VDPS_5SPR | VDPS_SCOL)
            VDPS |= (b5OnLine & ~(VDPS_INT | VDPS_5SPR | VDPS_SCOL)) | VDPS_5SPR
        } else {
            VDPS &= (VDPS_INT | VDPS_5SPR | VDPS_SCOL)
            VDPS |= (highest + 1) & ~(VDPS_INT | VDPS_5SPR | VDPS_SCOL)
        }
    }
}
