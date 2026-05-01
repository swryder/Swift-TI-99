// Swift 99/a
//
// ContentView.swift
// Main emulator display view. Renders VDP output frames from the DisplayBuffer
// inside a TI-99/4A monitor bezel image (Monitor.png from the asset catalog),
// and overlays optional performance statistics (FPS/MHz). Keyboard events are
// captured via a transparent NSView placed behind the display image.
//
// In Monitor Mode the window's chrome is hidden and its background is made
// transparent so only the bezel shape is visible against the desktop. The
// user can drag the window from anywhere on the bezel.

import SwiftUI
import AppKit

/// Primary emulator display — shows the TMS9918A video output framed by the
/// TI-99/4A monitor bezel, plus an optional performance overlay (FPS, MHz).
/// Keyboard input is forwarded to the Emulator for TI keyboard
/// matrix mapping.
struct ContentView: View {
    @ObservedObject var emulator: Emulator
    @ObservedObject var displayBuffer: DisplayBuffer

    // Monitor.png intrinsic size and screen-cutout proportions, measured
    // empirically from the painted screen area of the bezel image.
    private static let monitorAspect: CGFloat = 1267.0 / 910.0
    private static let cutoutOriginX: CGFloat = 0.1168
    private static let cutoutOriginY: CGFloat = 0.1527
    private static let cutoutWidth:   CGFloat = 0.5430
    private static let cutoutHeight:  CGFloat = 0.5901

    var body: some View {
        Group {
            if emulator.isMonitorMode {
                monitorBody
            } else {
                windowBody
            }
        }
        .background(WindowConfigurator(monitorMode: emulator.isMonitorMode))
        .onAppear {
            // start() is internally guarded against re-entry. We don't call
            // stop() on .onDisappear because toggling the styleMask causes
            // AppKit to remount the NSHostingView, which would otherwise tear
            // down the emulator (deInitSystem) while its background queue is
            // still reading memory — leading to an out-of-bounds crash.
            emulator.start()
        }
        .onKeyDown(handler: { keyCode, isDown in
            emulator.handleKey(keyCode: keyCode, isDown: isDown)
        }, charHandler: { char, isDown in
            emulator.handleCharKey(char: char, isDown: isDown)
        })
    }

    /// Plain window — just the VDP video, no bezel, with the FPS/MHz overlay
    /// in the bottom-left corner.
    private var windowBody: some View {
        ZStack(alignment: .bottomLeading) {
            videoView

            if emulator.showFPS || emulator.showMHz {
                performanceOverlay
                    .padding(8)
            }
        }
        .background(Color.black)
    }

    /// Monitor mode — video inset into the bezel cutout, with the area
    /// outside the bezel transparent so the desktop shows through.
    private var monitorBody: some View {
        GeometryReader { geo in
            // Fit the bezel image to the available space, preserving aspect ratio
            let availAspect = geo.size.width / geo.size.height
            let imgW = availAspect > Self.monitorAspect
                ? geo.size.height * Self.monitorAspect
                : geo.size.width
            let imgH = imgW / Self.monitorAspect

            ZStack {
                Color.clear

                let cutoutW = imgW * Self.cutoutWidth
                let cutoutH = imgH * Self.cutoutHeight

                // 5% margin on every side of the painted screen area in the bezel
                let hMargin = cutoutW * 0.05
                let vMargin = cutoutH * 0.05
                let availW = cutoutW - 2 * hMargin
                let availH = cutoutH - 2 * vMargin
                // Use the active TI display aspect (4:3) so the layer matches what
                // we actually show; the surrounding VDP border pixels are cropped out.
                let videoAspect = CGFloat(TMS_DISPLAY_WIDTH) / CGFloat(TMS_DISPLAY_HEIGHT)
                let baseVideoW = availW / availH > videoAspect ? availH * videoAspect : availW
                let videoW = baseVideoW + 25
                let videoH = videoW / videoAspect

                let videoCornerRadius = cutoutW * 0.05

                ZStack(alignment: .topLeading) {
                    // Bezel first, then video composited on top in the screen area.
                    Image("Monitor")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imgW, height: imgH)

                    RoundedVideoLayer(image: displayBuffer.currentFrame,
                                      cornerRadius: videoCornerRadius)
                        .frame(width: videoW, height: videoH)
                        .offset(x: imgW * Self.cutoutOriginX + (cutoutW - videoW) / 2,
                                y: imgH * Self.cutoutOriginY + (cutoutH - videoH) / 2)

                    if emulator.showFPS || emulator.showMHz {
                        performanceOverlay
                            .offset(x: imgW * Self.cutoutOriginX + 8,
                                    y: imgH * (Self.cutoutOriginY + Self.cutoutHeight) - 36)
                    }
                }
                .frame(width: imgW, height: imgH)

                // Single layer that handles both window-drag (everywhere) and
                // resize (bottom-left corner zone of the view).
                WindowDragView()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private var videoView: some View {
        if let frame = displayBuffer.currentFrame {
            Image(decorative: frame, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .aspectRatio(CGFloat(TMS_WIDTH) / CGFloat(TMS_HEIGHT), contentMode: .fit)
        } else {
            Rectangle()
                .fill(Color.black)
                .aspectRatio(CGFloat(TMS_WIDTH) / CGFloat(TMS_HEIGHT), contentMode: .fit)
        }
    }

    private var performanceOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            if emulator.showFPS {
                Text(String(format: "%.1f FPS", emulator.currentFPS))
            }
            if emulator.showMHz {
                Text(String(format: "%.2f MHz", emulator.currentMHz))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(.green)
        .padding(6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }
}

// MARK: - NSWindow chrome configuration

/// Toggles the host NSWindow between standard window chrome and a chromeless
/// "Monitor Mode" — transparent background, hidden title bar and traffic
/// lights, draggable by background.
private struct WindowConfigurator: NSViewRepresentable {
    let monitorMode: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            apply(to: w)
        }
    }

    private func apply(to w: NSWindow) {
        if monitorMode {
            // Remove .titled entirely so the title bar region disappears.
            w.styleMask.remove(.titled)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isMovableByWindowBackground = true
            w.hasShadow = true
        } else {
            // Restore .titled — AppKit recreates the standard buttons automatically.
            w.styleMask.insert(.titled)
            w.styleMask.remove(.fullSizeContentView)
            w.titleVisibility = .visible
            w.titlebarAppearsTransparent = false
            w.isOpaque = true
            w.backgroundColor = .black
            w.isMovableByWindowBackground = false
        }

        // Changing the styleMask resets the responder chain. Defer the
        // re-promotion past AppKit's own focus fixup so it sticks.
        DispatchQueue.main.async {
            restoreKeyboardFocus(in: w)
        }
    }
}

/// Invisible NSView that covers Monitor Mode content. Mouse-down anywhere
/// performs a window drag. The TI-99/4A had no mouse, so swallowing clicks
/// over the video area is harmless.
private struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            if let w = window {
                restoreKeyboardFocus(in: w)
            }
        }
    }
}

/// Walks the window's view tree and re-promotes the `KeyCaptureView` to
/// first responder. Used after operations that disrupt the responder chain
/// (styleMask changes, window-background drags).
private func restoreKeyboardFocus(in window: NSWindow) {
    if let cv = window.contentView, let kcv = findKeyCaptureView(in: cv) {
        window.makeFirstResponder(kcv)
    }
}

private func findKeyCaptureView(in view: NSView) -> KeyCaptureView? {
    if let kcv = view as? KeyCaptureView { return kcv }
    for sub in view.subviews {
        if let found = findKeyCaptureView(in: sub) { return found }
    }
    return nil
}

/// CALayer-backed view that renders the VDP frame with a true layer-level
/// corner radius. SwiftUI's `clipShape`/`cornerRadius`/`mask` modifiers don't
/// reliably affect `Image(decorative: cgImage)` content, so we bypass them
/// and feed the CGImage straight to a layer. `contentsRect` crops the frame
/// down to just the active 256×192 display, hiding the VDP's border pixels.
private struct RoundedVideoLayer: NSViewRepresentable {
    let image: CGImage?
    let cornerRadius: CGFloat

    // Active 256×192 display area within the 284×243 rendered frame.
    // CALayer's contentsRect is bottom-origin, so y is measured from the
    // bottom of the source image (the bottom border height).
    private static let activeRect = CGRect(
        x: CGFloat(TMS_FIRST_DISPLAY_PIXEL) / CGFloat(TMS_WIDTH),
        y: CGFloat(TMS_HEIGHT - TMS_FIRST_DISPLAY_LINE - TMS_DISPLAY_HEIGHT) / CGFloat(TMS_HEIGHT),
        width: CGFloat(TMS_DISPLAY_WIDTH) / CGFloat(TMS_WIDTH),
        height: CGFloat(TMS_DISPLAY_HEIGHT) / CGFloat(TMS_HEIGHT)
    )

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resize
        view.layer?.minificationFilter = .nearest
        view.layer?.magnificationFilter = .nearest
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsRect = Self.activeRect
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.contents = image
        nsView.layer?.contentsRect = Self.activeRect
    }
}
