// Swift 99/a
//
// Swift99aApp.swift
// Application entry point and menu bar configuration. Provides menu commands
// for loading cartridges (raw ROM files and Win994a .TiCart format), mounting
// V9T9 disk images, loading the TMS5220 speech ROM, controlling emulator speed,
// toggling performance overlays, resetting the system, and opening the memory
// map visualization window.

import SwiftUI
import UniformTypeIdentifiers

/// App delegate that sets the application name early, before menus are built.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set the process name so macOS uses it for the app menu title
        ProcessInfo.processInfo.processName = "Swift 99/a"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS auto-fills standard menu items with the app's display name
        // (CFBundleDisplayName, set in the Info.plist build settings to
        // "Swift 99/a"). The remaining items it sources from the bare
        // target/bundle name "Swift99a" — patch those so the slash-form is
        // used everywhere (e.g. "Hide Swift99a" → "Hide Swift 99/a").
        if let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu {
            appMenu.title = "Swift 99/a"
            for item in appMenu.items {
                item.title = item.title.replacingOccurrences(
                    of: "Swift99a", with: "Swift 99/a")
            }
        }
    }
}

/// The main application struct — configures the window, menu bar, and owns
/// the shared `Emulator` instance.
@main
struct Swift99aApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var emulator = Emulator()
    private let memoryMapController = MemoryMapWindowController()
    private let cassetteTransportController = CassetteTransportWindowController()
    private let crtControlsController = CRTControlsWindowController()

    init() {
        // Disable window tabbing before any windows are created
        // to prevent "Show Tab Bar" from flickering in the View menu
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("Swift 99/a") {
            ContentView(emulator: emulator, displayBuffer: emulator.displayBuffer)
                .frame(minWidth: 568, minHeight: 486)
        }
        .windowResizability(.contentSize)
        .commands {
            // Replace the default Open/New commands with our cartridge/disk loaders
            CommandGroup(replacing: .newItem) {
                Button("Open Cartridge…") {
                    openCartridgeFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Load TiCart…") {
                    openTiCartFile()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Remove Cartridge") {
                    emulator.removeCartridge()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(emulator.cartridgeName == nil)

                Divider()

                // Disk drive menus
                ForEach(1...3, id: \.self) { drive in
                    let diskName = emulator.diskNames[drive]
                    let isMounted = diskName != nil

                    Button(isMounted
                           ? "Unmount DSK\(drive) (\(diskName!))"
                           : "Mount Disk Image to DSK\(drive)…") {
                        if isMounted {
                            emulator.unmountDisk(drive: drive)
                        } else {
                            openDiskImage(drive: drive)
                        }
                    }
                }

                Divider()

                // Cassette tape (CS1)
                Button(emulator.cassetteName != nil
                       ? "Eject Cassette (\(emulator.cassetteName!))"
                       : "Load Cassette Tape…") {
                    if emulator.cassetteName != nil {
                        emulator.ejectCassette()
                    } else {
                        openCassetteFile()
                    }
                }

                Button("Show Cassette Transport") {
                    cassetteTransportController.showWindow(emulator: emulator)
                }
                .disabled(emulator.cassetteName == nil)

                Divider()

                // Speech ROM
                Button(emulator.speechROMLoaded
                       ? "Speech ROM Loaded"
                       : "Load Speech ROM (SPCHROM.BIN)…") {
                    if !emulator.speechROMLoaded {
                        openSpeechROM()
                    }
                }
                .disabled(emulator.speechROMLoaded)
            }

            // Edit menu: replace the standard Paste with one that types the
            // clipboard text into the TI as a stream of key events.
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    emulator.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(emulator.isPasting)
            }

            // Edit menu: speed control. Implemented as two Toggle items
            // (instead of a Picker) so each mode can carry its own keyboard
            // shortcut. Clicking the already-active mode is a no-op.
            CommandGroup(after: .pasteboard) {
                Divider()

                Toggle("Real TI-99/4A Speed", isOn: Binding(
                    get: { emulator.speedMode == .realTime },
                    set: { if $0 { emulator.setSpeedMode(.realTime) } }
                ))
                .keyboardShortcut("1", modifiers: [.command, .shift])

                Toggle("Maximum Speed", isOn: Binding(
                    get: { emulator.speedMode == .uncapped },
                    set: { if $0 { emulator.setSpeedMode(.uncapped) } }
                ))
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }

            // Replace default "Close" with "Quit" in File menu
            CommandGroup(replacing: .saveItem) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            // Sound menu
            CommandMenu("Sound") {
                Toggle("Mute Sound", isOn: $emulator.isMuted)
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }

            // Keyboard menu: TI-99/4A FCTN+number combos surfaced as
            // discoverable menu items with their ⌥+key equivalents shown
            // alongside. Mac keyCodes: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22,
            // 7=26, 8=28, 9=25, ==24. FCTN is Option (58).
            CommandMenu("Keyboard") {
                Button("DEL")    { emulator.injectKeys([58, 18]) }
                    .keyboardShortcut("1", modifiers: .option)
                Button("INS")    { emulator.injectKeys([58, 19]) }
                    .keyboardShortcut("2", modifiers: .option)
                Button("ERASE")  { emulator.injectKeys([58, 20]) }
                    .keyboardShortcut("3", modifiers: .option)
                Button("CLEAR")  { emulator.injectKeys([58, 21]) }
                    .keyboardShortcut("4", modifiers: .option)
                Button("BEGIN")  { emulator.injectKeys([58, 23]) }
                    .keyboardShortcut("5", modifiers: .option)
                Button("PROC'D") { emulator.injectKeys([58, 22]) }
                    .keyboardShortcut("6", modifiers: .option)
                Button("AID")    { emulator.injectKeys([58, 26]) }
                    .keyboardShortcut("7", modifiers: .option)
                Button("REDO")   { emulator.injectKeys([58, 28]) }
                    .keyboardShortcut("8", modifiers: .option)
                Button("BACK")   { emulator.injectKeys([58, 25]) }
                    .keyboardShortcut("9", modifiers: .option)
                Button("QUIT")   { emulator.injectKeys([58, 24]) }
                    .keyboardShortcut("=", modifiers: .option)
            }

            // View menu: performance overlays and window appearance
            CommandGroup(after: .toolbar) {
                Toggle("Window Mode", isOn: Binding(
                    get: { !emulator.isMonitorMode },
                    set: { if $0 { emulator.isMonitorMode = false } }
                ))

                Toggle("Monitor Mode", isOn: Binding(
                    get: { emulator.isMonitorMode },
                    set: { if $0 { emulator.isMonitorMode = true } }
                ))

                Divider()

                Toggle("Show FPS", isOn: $emulator.showFPS)
                    .keyboardShortcut("f", modifiers: [.command, .shift])

                Toggle("Show MHz", isOn: $emulator.showMHz)
                    .keyboardShortcut("z", modifiers: [.command, .shift])

                Divider()

                Button("Reset System") {
                    emulator.emulatorQueue.sync {
                        emulator.system.pCPU?.reset()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Show Memory Map") {
                    memoryMapController.showWindow(emulator: emulator)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("CRT Effects…") {
                    crtControlsController.showWindow(emulator: emulator)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - File Open Panels

    /// Opens a multi-selection panel for raw cartridge ROM files.
    /// File naming convention: C=ROM, D=Bank2 ROM, G=GROM
    private func openCartridgeFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Cartridge ROM"
        panel.message = "Select one or more cartridge files (C=ROM, D=Bank2, G=GROM)"
        panel.allowedContentTypes = [
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "rom")!,
            .init(filenameExtension: "grm")!,
            .data
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            emulator.loadCartridge(from: panel.urls)
        }
    }

    /// Opens a panel for Win994a .TiCart format cartridge files (LZW-compressed)
    private func openTiCartFile() {
        let panel = NSOpenPanel()
        panel.title = "Load TiCart Cartridge"
        panel.message = "Select a Win994a .TiCart cartridge file"
        panel.allowedContentTypes = [
            .init(filenameExtension: "ticart")!,
            .init(filenameExtension: "TiCart")!,
            .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            emulator.loadTiCart(from: url)
        }
    }

    /// Opens a panel for the TMS5220 Speech Synthesizer ROM (SPCHROM.BIN, 128KB)
    private func openSpeechROM() {
        let panel = NSOpenPanel()
        panel.title = "Load Speech ROM"
        panel.message = "Select SPCHROM.BIN (128KB TI Speech Synthesizer ROM)"
        panel.allowedContentTypes = [
            .init(filenameExtension: "bin")!,
            .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            emulator.loadSpeechROM(from: url)
        }
    }

    /// Opens a panel for cassette tape files. Audio recordings of real TI
    /// cassettes (WAV / MP3 / etc.) load into the internal 16 kHz PCM buffer.
    private func openCassetteFile() {
        let panel = NSOpenPanel()
        panel.title = "Load Cassette Tape"
        panel.message = "Select a tape audio file (.wav, .mp3)"
        panel.allowedContentTypes = [
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "wave")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "aif")!,
            .init(filenameExtension: "aiff")!,
            .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            emulator.loadCassette(from: url)
            cassetteTransportController.showWindow(emulator: emulator)
        }
    }

    /// Opens a panel for V9T9 disk images to mount on the given drive (1-3)
    private func openDiskImage(drive: Int) {
        let panel = NSOpenPanel()
        panel.title = "Mount Disk Image to DSK\(drive)"
        panel.allowedContentTypes = [
            .init(filenameExtension: "dsk")!,
            .init(filenameExtension: "tidisk")!,
            .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            emulator.mountDisk(drive: drive, from: url)
        }
    }
}
