// Swift 99/a
//
// TIKeyboard.swift
// Emulates the TI-99/4A keyboard via CRU I/O matrix scanning.
//
// The TI keyboard is an 8×8 matrix:
//   - Columns 0–7 are selected by writing to CRU bits 18–20 (3-bit column select)
//   - Rows 0–7 are read back on CRU bits 3–10 (active-low: 0 = key pressed)
//   - Columns 0 and 4 are joystick inputs (emulated via arrow keys)
//
// macOS keyboard events (from KeyboardEventView) are mapped to TI key
// positions in the matrix. Special key combinations are synthesized:
//   - Backspace → FCTN+S
//   - Escape → FCTN+9 (BACK)
//   - Tab → FCTN+7 (TAB)
//   - Single quotes/double quotes are handled specially

import Foundation
import GameController
import AppKit

/// TI-99/4A keyboard peripheral using CRU matrix scanning.
final class TIKeyboard: Peripheral {
    // The 8x8 key matrix maps Mac keyCodes to TI keyboard positions
    // Column is selected by CRU writes, rows are read back
    private var scanCol: Int = 0
    private var alphaActive: Bool = false

    // Current key state - updated from the main thread
    private var pressedKeys = Set<UInt16>()
    private let keyLock = NSRecursiveLock()

    // 99/4A keyboard matrix: [column][row] = macOS keyCode
    // Columns 0 and 4 are joystick columns
    // macOS keyCodes from CGKeyCode
    private let keyMatrix: [[UInt16]] = [
        // Col 0 - Joystick 2
        [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF],
        // Col 1: M J U 7 4 F R V
        [46, 38, 32, 26, 21, 3, 15, 9],
        // Col 2: / ; P 0 1 A Q Z
        [44, 41, 35, 29, 18, 0, 12, 6],
        // Col 3: . L O 9 2 S W X
        [47, 37, 31, 25, 19, 1, 13, 7],
        // Col 4 - Joystick 1
        [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF],
        // Col 5: , K I 8 3 D E C
        [43, 40, 34, 28, 20, 2, 14, 8],
        // Col 6: N H Y 6 5 G T B
        [45, 4, 16, 22, 23, 5, 17, 11],
        // Col 7: = SPACE ENTER (unused) ALT SHIFT CTRL (unused)
        // Note: Escape (53) is handled synthetically as FCTN+4 (break), not mapped here
        [24, 49, 36, 0xFFFF, 58, 56, 59, 0xFFFF]
    ]

    // Host keys that need special mapping to TI FCTN+key combos
    // Only for keys that don't work naturally through the keyboard matrix
    private var syntheticActive = Set<UInt16>()

    // Synthetic keyCode mappings: host keyCode -> [TI keyCodes to inject]
    // macOS keyCodes: 51=Delete/Backspace, 53=Escape, 123-126=arrow keys
    private static let syntheticKeys: [UInt16: [UInt16]] = [
        51:  [58, 1],   // Delete/Backspace -> FCTN(58) + S(1) = TI backspace
        53:  [58, 21],  // Escape -> FCTN(58) + 4(21) = TI CLEAR (break)
        123: [58, 1],   // Left arrow  -> FCTN + S = TI cursor left
        124: [58, 2],   // Right arrow -> FCTN + D = TI cursor right
        125: [58, 7],   // Down arrow  -> FCTN + X = TI cursor down
        126: [58, 14],  // Up arrow    -> FCTN + E = TI cursor up
    ]

    // Mac character -> TI matrix keys to inject. Lets the user type these
    // symbols using their natural Mac key positions; the emulator emits the
    // TI's FCTN+key combo so the BASIC ROM sees the right character.
    private static let charRemap: [Character: [UInt16]] = [
        "-":  [56, 44],   // SHIFT + / (TI's `-` is on the shift layer of /)
        "_":  [58, 32],   // FCTN + U  (Shift + - on Mac)
        "'":  [58, 31],   // FCTN + O
        "\"": [58, 35],   // FCTN + P  (Shift + ' on Mac)
        "?":  [58, 34],   // FCTN + I  (Shift + / on Mac)
        "[":  [58, 15],   // FCTN + R
        "]":  [58, 17],   // FCTN + T
        "{":  [58,  3],   // FCTN + F  (Shift + [ on Mac)
        "}":  [58,  5],   // FCTN + G  (Shift + ] on Mac)
        "~":  [58, 13],   // FCTN + W  (Shift + ` on Mac)
        "`":  [58,  8],   // FCTN + C
        "\\": [58,  6],   // FCTN + Z
    ]

    // Pairs of characters that share a single physical Mac key. If Shift
    // state changes between keyDown and keyUp, the up event arrives with
    // the sibling character — we use this to find the active remap to
    // tear down. Bidirectional so either ordering works.
    private static let shiftFallback: [Character: Character] = [
        "'": "\"",  "\"": "'",
        "[": "{",   "{": "[",
        "]": "}",   "}": "]",
        "`": "~",   "~": "`",
        "-": "_",   "_": "-",
        "/": "?",   "?": "/",
    ]

    // Mac keyCodes whose physical key is also in the TI matrix and would
    // otherwise be pressed alongside our synthesized keys. Currently only
    // '/' (44) — needed for '?' (Shift+/) so the matrix doesn't see both
    // FCTN+I and / at the same time.
    private static let suppressKeyCodesByChar: [Character: UInt16] = [
        "?": 44,
    ]

    /// Mac keyCode for each printable ASCII character that maps directly onto
    /// the TI key matrix (no modifiers needed). Letters appear once in their
    /// lowercase form; uppercase is produced by adding Shift in `matrixKeys`.
    private static let unshiftedKeyCode: [Character: UInt16] = [
        "a":  0, "b": 11, "c":  8, "d":  2, "e": 14, "f":  3, "g":  5,
        "h":  4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s":  1, "t": 17, "u": 32,
        "v":  9, "w": 13, "x":  7, "y": 16, "z":  6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        ";": 41, ",": 43, ".": 47, "/": 44, "=": 24,
        " ": 49,
    ]

    /// Mac keyCode reached by Shift+thatKey for shifted ASCII characters that
    /// produce the same character on the TI matrix when paired with Shift.
    /// (Curly quotes / FCTN-only TI chars live in `charRemap` instead.)
    private static let shiftedKeyCode: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23,
        "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
        ":": 41, "<": 43, ">": 47, "+": 24,
    ]

    /// Returns the list of Mac keyCodes (passed to keyDown/keyUp) that
    /// produce `c` on the TI keyboard. Returns nil for characters with no
    /// representation. Newline/CR map to ENTER, tab maps to space.
    static func matrixKeys(for c: Character) -> [UInt16]? {
        if c == "\n" || c == "\r" { return [36] }      // ENTER
        if c == "\t" { return [49] }                    // tab → space
        if let mapped = charRemap[c] { return mapped }
        if let code = unshiftedKeyCode[c] { return [code] }
        if c.isLetter, c.isUppercase {
            let lower = Character(c.lowercased())
            if let code = unshiftedKeyCode[lower] { return [56, code] }
        }
        if let code = shiftedKeyCode[c] { return [56, code] }
        return nil
    }

    // Active character remaps: down-character -> TI keys we injected.
    private var activeCharRemaps: [Character: [UInt16]] = [:]

    // Mac keyCodes whose keyDown is currently suppressed because a
    // character remap injected a TI combo for them.
    private var suppressedKeyCodes: Set<UInt16> = []

    func keyDown(keyCode: UInt16) {
        if let tiKeys = Self.syntheticKeys[keyCode] {
            keyLock.lock()
            syntheticActive.insert(keyCode)
            for tk in tiKeys { pressedKeys.insert(tk) }
            keyLock.unlock()
            return
        }

        keyLock.lock()
        if suppressedKeyCodes.contains(keyCode) {
            keyLock.unlock()
            return
        }
        pressedKeys.insert(keyCode)
        keyLock.unlock()
    }

    func keyUp(keyCode: UInt16) {
        if let tiKeys = Self.syntheticKeys[keyCode] {
            keyLock.lock()
            syntheticActive.remove(keyCode)
            for tk in tiKeys { pressedKeys.remove(tk) }
            keyLock.unlock()
            return
        }

        keyLock.lock()
        pressedKeys.remove(keyCode)
        keyLock.unlock()
    }

    /// Clear all pressed keys and synthetic state.
    /// Called after operations that steal keyboard focus (e.g., file dialogs)
    /// to prevent modifier keys from getting stuck.
    func clearAllKeys() {
        keyLock.lock()
        pressedKeys.removeAll()
        syntheticActive.removeAll()
        activeCharRemaps.removeAll()
        suppressedKeyCodes.removeAll()
        keyLock.unlock()
    }

    /// Handle character-based key remapping. Mac chars that aren't on the
    /// TI's key layout (e.g. `[`, `{`, `~`, `?`, `_`) are translated into
    /// the TI's FCTN+key combo so the user can type them at their natural
    /// Mac positions. See `charRemap` for the full table.
    func handleCharacterDown(_ char: Character) -> Bool {
        guard let tiKeys = Self.charRemap[char] else { return false }
        keyLock.lock()
        activeCharRemaps[char] = tiKeys
        syntheticActive.insert(0xFFFE)
        for k in tiKeys { pressedKeys.insert(k) }
        if let suppress = Self.suppressKeyCodesByChar[char] {
            suppressedKeyCodes.insert(suppress)
        }
        keyLock.unlock()
        return true
    }

    func handleCharacterUp(_ char: Character) -> Bool {
        keyLock.lock()
        defer { keyLock.unlock() }

        // Find the active remap for this release. Direct match first;
        // if Shift state changed between down and up, the up event may
        // arrive with the sibling character (e.g. down=`{`, up=`[`).
        let downChar: Character
        if activeCharRemaps[char] != nil {
            downChar = char
        } else if let alt = Self.shiftFallback[char], activeCharRemaps[alt] != nil {
            downChar = alt
        } else {
            return false
        }

        guard let keys = activeCharRemaps.removeValue(forKey: downChar) else {
            return false
        }
        for k in keys { pressedKeys.remove(k) }
        if let suppress = Self.suppressKeyCodesByChar[downChar] {
            suppressedKeyCodes.remove(suppress)
        }
        if activeCharRemaps.isEmpty {
            syntheticActive.remove(0xFFFE)
        }
        return true
    }

    private func isKeyPressed(_ keyCode: UInt16) -> Bool {
        if keyCode == 0xFFFF { return false }
        keyLock.lock()
        let result = pressedKeys.contains(keyCode)
        keyLock.unlock()
        return result
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        // Alpha lock check (addr 7 when alpha is active)
        if addr == 0x07 && alphaActive {
            // Check caps lock state - inverted for easier use
            return NSEvent.modifierFlags.contains(.capsLock) ? 1 : 0
        }

        // Joystick columns (0 and 4)
        if scanCol == 0 || scanCol == 4 {
            return checkJoystick(addr: addr, index: scanCol == 0 ? 1 : 0)
        }

        // Check keyboard matrix
        guard scanCol < 8 && (addr - 3) >= 0 && (addr - 3) < 8 else { return 1 }
        let keyCode = keyMatrix[scanCol][addr - 3]

        if isKeyPressed(keyCode) {
            return 0
        }

        // Check right-side modifier keys as alternatives
        if keyCode == 58 && isKeyPressed(61) { return 0 }  // Right Option for Left Option
        if keyCode == 56 && isKeyPressed(60) { return 0 }  // Right Shift for Left Shift
        if keyCode == 59 && isKeyPressed(62) { return 0 }  // Right Control for Left Control

        return 1
    }

    private func checkJoystick(addr: Int, index: Int) -> UInt8 {
        // Joystick 1 maps to the numeric keypad: 8/2/4/6 cardinals,
        // 7/9/1/3 diagonals (each pressing both component directions),
        // and Keypad Enter for Fire. Mac keyCodes:
        //   76 Enter, 83 1, 84 2, 85 3, 86 4, 88 6, 89 7, 91 8, 92 9
        if index == 0 {
            switch addr {
            case 3: return isKeyPressed(76) ? 0 : 1  // Keypad Enter = Fire
            case 4: return (isKeyPressed(86) || isKeyPressed(89) || isKeyPressed(83)) ? 0 : 1  // Left  (4, 7, 1)
            case 5: return (isKeyPressed(88) || isKeyPressed(92) || isKeyPressed(85)) ? 0 : 1  // Right (6, 9, 3)
            case 6: return (isKeyPressed(84) || isKeyPressed(83) || isKeyPressed(85)) ? 0 : 1  // Down  (2, 1, 3)
            case 7: return (isKeyPressed(91) || isKeyPressed(89) || isKeyPressed(92)) ? 0 : 1  // Up    (8, 7, 9)
            default: return 1
            }
        }
        return 1
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        switch addr {
        case 0x12:
            scanCol = (scanCol & 0x3) | (data != 0 ? 0 : 4)
        case 0x13:
            scanCol = (scanCol & 0x5) | (data != 0 ? 0 : 2)
        case 0x14:
            scanCol = (scanCol & 0x6) | (data != 0 ? 0 : 1)
        case 0x15:
            alphaActive = (data == 0)
        default:
            break
        }
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TIKeyboard", index: index)
        return true
    }
}
