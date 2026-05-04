// Swift 99/a
//
// CassetteTransportView.swift
// Floating window with the cassette deck transport controls — Play, Stop,
// Rewind to start, plus the loaded tape's name and a playback position bar.
//
// On real hardware the user has to physically press PLAY on the cassette
// recorder for the tape to move; the CPU's motor signal is only the second
// gate. This window stands in for those buttons. Loading a tape image is
// equivalent to inserting a cassette into the deck — the transport stays in
// the Stopped state until the user presses Play.

import SwiftUI
import AppKit
import Combine

struct CassetteTransportView: View {
    @ObservedObject var emulator: Emulator

    /// Polls the cassette's playback position 10× per second so the progress
    /// bar updates smoothly without publishing on every audio buffer.
    private let positionTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    @State private var progress: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "tape")
                    .font(.system(size: 18))
                Text(emulator.cassetteName ?? "No Tape Loaded")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            HStack(spacing: 16) {
                Button { emulator.rewindCassette() } label: {
                    Label("Rewind", systemImage: "backward.end.fill")
                }
                .help("Rewind to start of tape")

                Button { emulator.playCassette() } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .help("Press PLAY on the cassette deck")
                .disabled(emulator.cassetteTransportState == .play)

                Button { emulator.stopCassette() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the tape mechanism")
                .disabled(emulator.cassetteTransportState == .stopped)

                Spacer()

                Text(stateLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .disabled(emulator.cassetteName == nil)
        .onReceive(positionTimer) { _ in
            // Read the cassette's current playback fraction. Direct access
            // is safe enough for a UI position indicator (Double reads are
            // atomic on Apple Silicon and we only display the value).
            progress = emulator.system.pCassette?.progress ?? 0
        }
    }

    private var stateLabel: String {
        guard emulator.cassetteName != nil else { return "EMPTY" }
        switch emulator.cassetteTransportState {
        case .play:    return "▶ PLAY"
        case .stopped: return "■ STOP"
        }
    }
}

/// Manages the standalone cassette transport NSWindow. Mirrors the pattern
/// used by `MemoryMapWindowController`: a single reusable window that's
/// shown on demand and hidden but kept around when closed.
final class CassetteTransportWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func showWindow(emulator: Emulator) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = CassetteTransportView(emulator: emulator)
        let hostingView = NSHostingView(rootView: view)

        let contentSize = NSSize(width: 360, height: 140)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cassette Transport"
        window.contentView = hostingView
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
