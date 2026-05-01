// Swift 99/a
//
// KeyboardEventView.swift
// Bridges macOS AppKit keyboard events into SwiftUI. SwiftUI alone does not
// expose raw keyCode values or reliable key-up events, so we embed a
// transparent NSView (KeyCaptureView) as a first responder to capture
// keyDown/keyUp/flagsChanged events. These are forwarded via closures to
// the Emulator, which maps macOS key codes to the TI-99/4A
// keyboard matrix.
//
// Architecture:
//   KeyCaptureView  (NSView)     — captures AppKit keyboard events
//   KeyboardCaptureView          — NSViewRepresentable wrapper for SwiftUI
//   KeyDownModifier / .onKeyDown — ViewModifier convenience for attaching
//                                  keyboard handling to any SwiftUI view

import SwiftUI
import AppKit

/// NSView subclass that captures raw keyboard events and forwards them
/// via closures. Both hardware key codes and resolved characters are reported.
class KeyCaptureView: NSView {
    /// Called with (keyCode, isDown) for every key press and release
    var onKeyDown: ((UInt16, Bool) -> Void)?
    /// Called with (character, isDown) for resolved character input (handles Shift, etc.)
    var onCharKey: ((Character, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Try character-based mapping first (for shifted punctuation like ", !, etc.)
        if let chars = event.characters, let char = chars.first {
            onCharKey?(char, true)
        }
        onKeyDown?(event.keyCode, true)
    }

    override func keyUp(with event: NSEvent) {
        if let chars = event.characters, let char = chars.first {
            onCharKey?(char, false)
        }
        onKeyDown?(event.keyCode, false)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys — map AppKit modifier flags to their virtual key codes
        // so the emulator can track Shift/Control/Fctn state for the TI keyboard matrix
        let modifiers: [(NSEvent.ModifierFlags, UInt16)] = [
            (.shift, 56),    // Left Shift
            (.control, 59),  // Left Control → TI Control key
            (.option, 58),   // Left Option  → TI Fctn key
        ]
        for (flag, code) in modifiers {
            onKeyDown?(code, event.modifierFlags.contains(flag))
        }
    }
}

/// NSViewRepresentable wrapper that embeds a `KeyCaptureView` into SwiftUI.
/// On creation, the view is promoted to first responder so it begins
/// receiving keyboard events immediately.
struct KeyboardCaptureView: NSViewRepresentable {
    let onKeyEvent: (UInt16, Bool) -> Void
    var onCharEvent: ((Character, Bool) -> Void)?

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKeyDown = onKeyEvent
        view.onCharKey = onCharEvent
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onKeyDown = onKeyEvent
        nsView.onCharKey = onCharEvent
    }
}

/// View modifier that attaches an invisible `KeyboardCaptureView` as a
/// background layer, enabling any SwiftUI view to receive keyboard events.
struct KeyDownModifier: ViewModifier {
    let handler: (UInt16, Bool) -> Void
    var charHandler: ((Character, Bool) -> Void)?

    func body(content: Content) -> some View {
        content.background(
            KeyboardCaptureView(onKeyEvent: handler, onCharEvent: charHandler)
        )
    }
}

extension View {
    func onKeyDown(handler: @escaping (UInt16, Bool) -> Void, charHandler: ((Character, Bool) -> Void)? = nil) -> some View {
        modifier(KeyDownModifier(handler: handler, charHandler: charHandler))
    }
}
