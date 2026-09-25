import AppKit
import ImageIO
import SwiftData
import SwiftUI

/// The Markup window: draw arrows, boxes, highlights and text on a screenshot, pixelate private
/// details, and crop. "Done" saves the result as a *new* screenshot next to the original (which
/// is never modified) and copies it to the clipboard.
struct MarkupEditorView: View {
    let screenshotID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var screenshot: Screenshot?
    @State private var renderer: MarkupRenderer?
    @State private var loadFailed = false

    @State private var history = MarkupHistory()
    @State private var tool: MarkupTool = .arrow
    @State private var color: MarkupColor = .red
    @State private var size: MarkupSize = .medium

    /// The mark being dragged out right now, drawn live but not yet in `history`.
    @State private var pendingMark: MarkupAnnotation?
    @State private var pendingCrop: CGRect?

    /// Where the text being typed will sit, in image pixels. `nil` when no text is being typed.
    @State private var textOrigin: CGPoint?
    @State private var textDraft = ""
    @FocusState private var isTextFieldFocused: Bool

    @State private var isConfirmingDiscard = false
    @State private var isSaving = false
    @State private var saveFailed = false

    private static let canvasPadding: CGFloat = 24

    var body: some View {
        Group {
            if let renderer {
                VStack(spacing: 0) {
                    canvas(renderer)
                    Divider()
                    styleBar
                }
            } else if loadFailed {
                ContentUnavailableView(
                    "Can't Open Screenshot",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file may have been moved or deleted.")
                )
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle(screenshot.map { "Markup — \($0.originalName)" } ?? "Markup")
        .toolbar { toolbarContent }
        .task { load() }
        .onChange(of: tool) { _, _ in commitText() }
        .confirmationDialog("Discard your markup?", isPresented: $isConfirmingDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Couldn't Save Markup", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Canvas

    private func canvas(_ renderer: MarkupRenderer) -> some View {
        GeometryReader { geometry in
            let available = CGSize(
                width: max(0, geometry.size.width - Self.canvasPadding * 2),
                height: max(0, geometry.size.height - Self.canvasPadding * 2)
            )
            let displaySize = MarkupGeometry.fittedRect(imageSize: renderer.imageSize, in: available).size
            let scale = renderer.imageSize.width > 0 ? displaySize.width / renderer.imageSize.width : 1

            Canvas { context, _ in
                context.withCGContext { cgContext in
                    cgContext.scaleBy(x: scale, y: scale)
                    renderer.draw(history.document, pending: pendingMark, in: cgContext)
                }
                drawCropOverlay(in: &context, displaySize: displaySize, scale: scale)
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .overlay(alignment: .topLeading) {
                textField(scale: scale)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .contentShape(Rectangle())
            .gesture(drawGesture(displaySize: displaySize, imageSize: renderer.imageSize))
            .onContinuousHover { phase in
                if case .active = phase { cursor.set() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var cursor: NSCursor {
        tool == .text ? .iBeam : .crosshair
    }

    /// Dims everything outside the crop and outlines it. Screen-only — the export crops instead.
    private func drawCropOverlay(in context: inout GraphicsContext, displaySize: CGSize, scale: CGFloat) {
        guard let crop = pendingCrop ?? history.document.cropRect else { return }
        let cropInView = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)

        var dimmed = Path(CGRect(origin: .zero, size: displaySize))
        dimmed.addRect(cropInView)
        context.fill(dimmed, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        context.stroke(Path(cropInView), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    @ViewBuilder
    private func textField(scale: CGFloat) -> some View {
        if let textOrigin {
            let fontSize = MarkupGeometry.fontSize(for: size, imageSize: renderer?.imageSize ?? .zero) * scale
            TextField("Type text", text: $textDraft)
                .textFieldStyle(.plain)
                .font(.system(size: max(fontSize, 11), weight: .bold))
                .foregroundStyle(Color(cgColor: color.cgColor))
                .frame(minWidth: 160)
                .fixedSize()
                .padding(.horizontal, 2)
                .background(.background.opacity(0.35))
                .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .offset(x: textOrigin.x * scale, y: textOrigin.y * scale)
                .focused($isTextFieldFocused)
                .onSubmit { commitText() }
                .onExitCommand { cancelText() }
        }
    }

    // MARK: - Drawing

    private func drawGesture(displaySize: CGSize, imageSize: CGSize) -> some Gesture {
        let displayRect = CGRect(origin: .zero, size: displaySize)
        func imagePoint(_ point: CGPoint) -> CGPoint {
            MarkupGeometry.imagePoint(fromView: point, displayRect: displayRect, imageSize: imageSize)
        }

        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Starting any other mark finishes the text being typed.
                if tool != .text, textOrigin != nil { commitText() }

                let start = imagePoint(value.startLocation)
                let current = imagePoint(value.location)
                switch tool {
                case .arrow:
                    pendingMark = mark(.arrow(from: start, to: current))
                case .rectangle:
                    pendingMark = mark(.rectangle(MarkupGeometry.rect(from: start, to: current)))
                case .blur:
                    pendingMark = mark(.blur(MarkupGeometry.rect(from: start, to: current)))
                case .highlighter:
                    if case .highlight(let points) = pendingMark?.kind {
                        pendingMark?.kind = .highlight(points + [current])
                    } else {
                        pendingMark = mark(.highlight([start]))
                    }
                case .crop:
                    pendingCrop = MarkupGeometry.rect(from: start, to: current)
                case .text:
                    break
                }
            }
            .onEnded { value in
                // Ignores accidental clicks for the shape tools; a 3pt drag is clearly deliberate.
                let movedEnough = hypot(value.translation.width, value.translation.height) >= 3
                switch tool {
                case .text:
                    commitText()
                    beginText(at: imagePoint(value.location), imageSize: imageSize)
                case .crop:
                    if movedEnough, let pendingCrop {
                        history.commit { $0.cropRect = pendingCrop }
                    }
                    pendingCrop = nil
                case .highlighter:
                    commitPendingMark()
                case .arrow, .rectangle, .blur:
                    if movedEnough { commitPendingMark() }
                }
                pendingMark = nil
            }
    }

    private func mark(_ kind: MarkupAnnotation.Kind) -> MarkupAnnotation {
        MarkupAnnotation(id: pendingMark?.id ?? UUID(), kind: kind, color: color, size: size)
    }

    private func commitPendingMark() {
        guard let pendingMark else { return }
        history.commit { $0.annotations.append(pendingMark) }
    }

    // MARK: - Text

    private func beginText(at point: CGPoint, imageSize: CGSize) {
        // Centers the first line on the click rather than hanging below it.
        let fontSize = MarkupGeometry.fontSize(for: size, imageSize: imageSize)
        textOrigin = CGPoint(x: point.x, y: max(0, point.y - fontSize * 0.6))
        textDraft = ""
        isTextFieldFocused = true
    }

    private func commitText() {
        defer { cancelText() }
        guard let textOrigin else { return }
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let annotation = MarkupAnnotation(kind: .text(text, at: textOrigin), color: color, size: size)
        history.commit { $0.annotations.append(annotation) }
    }

    private func cancelText() {
        textOrigin = nil
        textDraft = ""
        isTextFieldFocused = false
    }

    // MARK: - Style bar

    private var styleBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(MarkupColor.allCases) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        Circle()
                            .fill(Color(cgColor: swatch.cgColor))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().strokeBorder(color == swatch ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.title)
                    .accessibilityLabel(swatch.title)
                    .accessibilityAddTraits(color == swatch ? .isSelected : [])
                }
            }

            Picker("Size", selection: $size) {
                ForEach(MarkupSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(!tool.usesStyle)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hint: String {
        switch tool {
        case .arrow: "Drag to draw an arrow"
        case .rectangle: "Drag to draw a box"
        case .highlighter: "Drag to highlight"
        case .text: "Click to add text, then press Return"
        case .blur: "Drag over anything private to pixelate it"
        case .crop: "Drag to choose the area to keep"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Cancel") {
                if history.document.isEmpty { dismiss() } else { isConfirmingDiscard = true }
            }
        }

        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $tool) {
                ForEach(MarkupTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage)
                        .labelStyle(.iconOnly)
                        .help(tool.title)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button("Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!history.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { history.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!history.canRedo)
            }

            Button("Done") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(renderer == nil || isSaving || (history.document.isEmpty && textDraft.isEmpty))
                .help("Save as a new screenshot and copy it (⌘Return)")
        }
    }

    // MARK: - Load / save

    private func load() {
        guard renderer == nil else { return }
        let descriptor = FetchDescriptor<Screenshot>(predicate: #Predicate { $0.id == screenshotID })
        guard let found = try? modelContext.fetch(descriptor).first,
              let source = CGImageSourceCreateWithURL(found.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            loadFailed = true
            return
        }
        screenshot = found
        renderer = MarkupRenderer(image: image)
    }

    private func save() {
        commitText()
        guard let renderer, let screenshot, let data = renderer.exportPNG(history.document) else {
            saveFailed = true
            return
        }
        isSaving = true
        let name = "\(screenshot.originalName) (Markup)"
        Task {
            defer { isSaving = false }
            guard let id = try? await appState.importImage(data: data, suggestedName: name) else {
                saveFailed = true
                return
            }
            if let saved = modelContext.model(for: id) as? Screenshot {
                appState.pasteboardService.copy([saved])
            }
            dismiss()
        }
    }
}
