// Swift 99/a
//
// DisplayBuffer.swift
// Bridge between the VDP's rendered frames and SwiftUI's display layer.
// The VDP pushes completed CGImage frames here; SwiftUI observes the
// @Published property to trigger view redraws at ~60 Hz.

import Foundation
import SwiftUI
import CoreGraphics
import Combine

/// Bridge between the VDP's rendered frames and SwiftUI's display layer.
/// The VDP calls `updateFrame(_:)` to deliver new frames; SwiftUI observes
/// the `@Published currentFrame` to redraw the emulator display.
final class DisplayBuffer: ObservableObject {
    @Published var currentFrame: CGImage?

    /// Running count of frames delivered (for FPS calculation)
    var framesPushed: Int = 0

    /// Called from VDP's pushFrame() to deliver a new frame
    func updateFrame(_ image: CGImage) {
        framesPushed += 1
        DispatchQueue.main.async {
            self.currentFrame = image
        }
    }
}
