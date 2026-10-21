import SwiftUI
import AppKit

struct WaveformView: View {
    let data: WaveformData?
    let progress: Double
    let onSeek: (Double) -> Void
    let dragPayloadProvider: (Double, Double) async throws -> WaveformDragPayload

    @Binding var selection: ClosedRange<Double>?
    @State private var renderedData: WaveformData?
    @State private var outgoingData: WaveformData?
    @State private var transitionProgress: Double = 1
    @State private var transitionGeneration: UInt64 = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.panelSunken)

                if let selection {
                    let width = CGFloat(selection.upperBound - selection.lowerBound) * geometry.size.width
                    let center = CGFloat((selection.lowerBound + selection.upperBound) / 2) * geometry.size.width
                    Rectangle()
                        .fill(AppTheme.accent.opacity(0.18))
                        .frame(width: width, height: geometry.size.height)
                        .position(x: center, y: geometry.size.height / 2)
                }

                if let visibleData = renderedData ?? data {
                    ZStack {
                        if let outgoingData {
                            waveformCanvas(data: outgoingData, size: geometry.size)
                                .opacity(1 - transitionProgress)
                        }
                        waveformCanvas(data: visibleData, size: geometry.size)
                            .opacity(transitionProgress)
                    }
                    let playheadX = min(
                        max(CGFloat(min(max(progress, 0), 1)) * geometry.size.width, 0.75),
                        max(geometry.size.width - 0.75, 0.75)
                    )
                    Rectangle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 1.5, height: geometry.size.height)
                        .position(x: playheadX, y: geometry.size.height / 2)
                } else {
                    HStack(spacing: 8) {
                        InlineSpinner(size: 13, lineWidth: 1.5)
                        Text("Analyzing waveform…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .overlay {
                WaveformInteractionLayer(
                    selection: $selection,
                    onSeek: onSeek,
                    dragPayloadProvider: dragPayloadProvider
                )
            }
        }
        .onAppear { renderedData = data }
        .onChange(of: renderIdentity) { _, _ in
            guard let data else {
                renderedData = nil
                outgoingData = nil
                return
            }
            let shouldCrossfade = renderedData?.fidelity == .provisional && data.fidelity == .exact
                && renderedData?.signature == data.signature
            transitionGeneration &+= 1
            let generation = transitionGeneration
            if shouldCrossfade {
                outgoingData = renderedData
                renderedData = data
                transitionProgress = 0
                withAnimation(.easeInOut(duration: 0.1)) { transitionProgress = 1 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    if generation == transitionGeneration, transitionProgress == 1 { outgoingData = nil }
                }
            } else {
                renderedData = data
                outgoingData = nil
                transitionProgress = 1
            }
        }
    }

    private var renderIdentity: String {
        guard let data else { return "none" }
        return "\(data.signature.contentHash):\(data.signature.fileSize):\(data.signature.modificationNanoseconds):\(data.fidelity.rawValue):\(data.levels.last?.bucketCount ?? 0)"
    }

    @ViewBuilder
    private func waveformCanvas(data: WaveformData, size: CGSize) -> some View {
        let playedWidth = CGFloat(min(max(progress, 0), 1)) * size.width
        // Read observable colors while building the view, before Canvas draws
        // asynchronously, so changing a color refreshes a paused waveform too.
        let waveformColor = AppTheme.waveform
        let playedColor = AppTheme.waveformPlayed

        Canvas(rendersAsynchronously: true) { context, canvasSize in
            let waveRect = CGRect(origin: .zero, size: canvasSize)

            guard let level = data.level(forPixelWidth: canvasSize.width, visibleFraction: 1) else { return }
            let channelCount = min(level.channels.count, 2)

            for channel in 0..<channelCount {
                let laneHeight = waveRect.height / CGFloat(channelCount)
                let lane = CGRect(
                    x: waveRect.minX,
                    y: waveRect.minY + CGFloat(channel) * laneHeight,
                    width: waveRect.width,
                    height: laneHeight
                ).insetBy(dx: 0, dy: channelCount == 1 ? 10 : 6)

                var center = Path()
                center.move(to: CGPoint(x: lane.minX, y: lane.midY))
                center.addLine(to: CGPoint(x: lane.maxX, y: lane.midY))
                context.stroke(center, with: .color(.white.opacity(0.13)), lineWidth: 0.75)

                let envelope = envelopePath(
                    peaks: level.channels[channel],
                    bucketCount: level.bucketCount,
                    rect: lane
                )
                context.fill(envelope, with: .color(waveformColor.opacity(0.82)))
                context.stroke(envelope, with: .color(.white.opacity(0.16)), lineWidth: 0.45)

                if playedWidth > 0 {
                    var played = context
                    played.clip(to: Path(CGRect(
                        x: 0,
                        y: lane.minY,
                        width: min(playedWidth, canvasSize.width),
                        height: lane.height
                    )))
                    played.fill(envelope, with: .color(playedColor.opacity(0.96)))
                }

                if channelCount == 2 {
                    context.draw(
                        Text(channel == 0 ? "L" : "R")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.secondary.opacity(0.7)),
                        at: CGPoint(x: 9, y: lane.minY + 8)
                    )
                }
            }

        }
    }

    private func envelopePath(
        peaks: [WaveformPeak],
        bucketCount: Int,
        rect: CGRect
    ) -> Path {
        let count = min(peaks.count, bucketCount)
        guard count > 0 else { return Path() }
        let scale = rect.height * 0.48

        func x(_ boundary: Int) -> CGFloat {
            CGFloat(boundary) / CGFloat(count) * rect.width + rect.minX
        }
        func upper(_ peak: WaveformPeak) -> CGFloat {
            rect.midY - CGFloat(min(max(peak.maximum, -1), 1)) * scale
        }
        func lower(_ peak: WaveformPeak) -> CGFloat {
            rect.midY - CGFloat(min(max(peak.minimum, -1), 1)) * scale
        }

        var path = Path()
        path.move(to: CGPoint(x: x(0), y: upper(peaks[0])))
        for index in 0..<count {
            path.addLine(to: CGPoint(x: x(index), y: upper(peaks[index])))
            path.addLine(to: CGPoint(x: x(index + 1), y: upper(peaks[index])))
        }
        for index in stride(from: count - 1, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: x(index + 1), y: lower(peaks[index])))
            path.addLine(to: CGPoint(x: x(index), y: lower(peaks[index])))
        }
        path.closeSubpath()
        return path
    }

}

struct WaveformDragPayload {
    let writer: any NSPasteboardWriting
}

private struct WaveformInteractionLayer: NSViewRepresentable {
    @Binding var selection: ClosedRange<Double>?
    let onSeek: (Double) -> Void
    let dragPayloadProvider: (Double, Double) async throws -> WaveformDragPayload

    func makeNSView(context: Context) -> WaveformInteractionNSView {
        WaveformInteractionNSView()
    }

    func updateNSView(_ view: WaveformInteractionNSView, context: Context) {
        view.selection = selection
        view.onSelectionChange = { selection = $0 }
        view.onSeek = onSeek
        view.dragPayloadProvider = dragPayloadProvider
    }
}

private final class WaveformInteractionNSView: NSView, NSDraggingSource {
    var selection: ClosedRange<Double>?
    var onSelectionChange: ((ClosedRange<Double>?) -> Void)?
    var onSeek: ((Double) -> Void)?
    var dragPayloadProvider: ((Double, Double) async throws -> WaveformDragPayload)?

    private var mouseDownFraction: Double = 0
    private var mouseDownPoint: CGPoint = .zero
    private var startedInsideSelection = false
    private var beganFileDrag = false
    private var dragPreparation: Task<Void, Never>?
    private var dragGeneration: UInt64 = 0

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDragPreparation() }
    }

    private func cancelDragPreparation() {
        dragGeneration &+= 1
        dragPreparation?.cancel()
        dragPreparation = nil
    }

    override func mouseDown(with event: NSEvent) {
        cancelDragPreparation()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownFraction = fraction(at: mouseDownPoint.x)
        startedInsideSelection = selection?.contains(mouseDownFraction) == true
        beganFileDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        guard distance >= 3 else { return }

        if startedInsideSelection {
            guard !beganFileDrag, let selection, let dragPayloadProvider else { return }
            beganFileDrag = true
            let generation = dragGeneration
            dragPreparation = Task { [weak self] in
                do {
                    let payload = try await dragPayloadProvider(selection.lowerBound, selection.upperBound)
                    guard let self, !Task.isCancelled, self.dragGeneration == generation,
                          self.window != nil, self.selection == selection,
                          NSEvent.pressedMouseButtons & 1 != 0 else { return }
                    let item = NSDraggingItem(pasteboardWriter: payload.writer)
                    let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "Audio selection"))
                    item.setDraggingFrame(NSRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36), contents: image)
                    self.beginDraggingSession(with: [item], event: event, source: self)
                } catch is CancellationError {
                    return
                } catch {
                    NSSound.beep()
                }
            }
            return
        }

        let current = fraction(at: point.x)
        let updated = min(mouseDownFraction, current)...max(mouseDownFraction, current)
        selection = updated
        onSelectionChange?(updated)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            cancelDragPreparation()
            beganFileDrag = false
        }
        guard !startedInsideSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        if distance < 3 {
            selection = nil
            onSelectionChange?(nil)
            onSeek?(fraction(at: point.x))
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        cancelDragPreparation()
    }

    private func fraction(at x: CGFloat) -> Double {
        min(max(Double(x / max(bounds.width, 1)), 0), 1)
    }
}
