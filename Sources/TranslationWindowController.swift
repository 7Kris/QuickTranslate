import AppKit
import SwiftUI

class TranslationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel = TranslationViewModel()
    var onTranslate: ((String, TranslationLanguage?, TranslationLanguage?) -> Void)?
    var onClose: (() -> Void)?

    func show(original: String, result: String?, isError: Bool) {
        viewModel.originalText = original
        viewModel.translatedText = result ?? ""
        viewModel.isLoading = result == nil && !original.isEmpty
        viewModel.isError = isError

        if window == nil {
            createWindow()
        }

        positionWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateForRetranslation(original: String) {
        viewModel.originalText = original
        viewModel.translatedText = ""
        viewModel.isLoading = true
        viewModel.isError = false
    }

    func updateResult(_ result: String, sourceLanguage: TranslationLanguage? = nil, targetLanguage: TranslationLanguage? = nil) {
        viewModel.translatedText = result
        viewModel.isLoading = false
        if let source = sourceLanguage { viewModel.sourceLanguage = source }
        if let target = targetLanguage { viewModel.targetLanguage = target }
    }

    func setError(_ isError: Bool) {
        viewModel.isError = isError
    }

    private func createWindow() {
        let contentView = TranslationView(viewModel: viewModel, onClose: { [weak self] in
            self?.close()
        }, onTranslate: { [weak self] text, source, target in
            self?.onTranslate?(text, source, target)
        }, onSwap: { [weak self] in
            self?.swapTexts()
            if let text = self?.viewModel.originalText, !text.isEmpty {
                let source = self?.viewModel.sourceLanguage
                let target = self?.viewModel.targetLanguage
                self?.onTranslate?(text, target, source)
            }
        })

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = "QuickTranslate"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 400, height: 300)

        // タイトルバーにフォントサイズUIを組み込む
        let fontSizeView = NSHostingView(rootView: TitlebarControlView(viewModel: viewModel))
        fontSizeView.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = fontSizeView
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        window.delegate = self

        self.window = window
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowFrame = window?.frame ?? .zero
        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.midY - windowFrame.height / 2 + screenFrame.height * 0.15
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func swapTexts() {
        let swapped = viewModel.translatedText
        viewModel.originalText = swapped
        viewModel.translatedText = ""
        viewModel.isLoading = !swapped.isEmpty
        viewModel.isError = false
    }

    private func close() {
        window?.orderOut(nil)
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

class TranslationViewModel: ObservableObject {
    private static let fontSizeKey = "TranslationFontSize"
    private static let defaultFontSize: CGFloat = 16
    private static let horizontalSplitKey = "TranslationHorizontalSplit"

    @Published var originalText: String = ""
    @Published var translatedText: String = ""
    @Published var isLoading: Bool = false
    @Published var isError: Bool = false
    @Published var sourceLanguage: TranslationLanguage = .english
    @Published var targetLanguage: TranslationLanguage = .japanese
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }
    @Published var isHorizontalSplit: Bool {
        didSet { UserDefaults.standard.set(isHorizontalSplit, forKey: Self.horizontalSplitKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? saved : Self.defaultFontSize
        self.isHorizontalSplit = UserDefaults.standard.bool(forKey: Self.horizontalSplitKey)
    }
}

struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel
    var onClose: () -> Void
    var onTranslate: (String, TranslationLanguage?, TranslationLanguage?) -> Void
    var onSwap: () -> Void

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("原文")
                    .font(.body)
                    .foregroundColor(.secondary)
                Picker("", selection: $viewModel.sourceLanguage) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: viewModel.sourceLanguage) { _ in
                    if viewModel.sourceLanguage == viewModel.targetLanguage {
                        viewModel.targetLanguage = viewModel.sourceLanguage == .japanese ? .english : .japanese
                    }
                    retranslateIfNeeded()
                }
            }
            TextEditor(text: $viewModel.originalText)
                .font(.system(size: viewModel.fontSize))
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var translatedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("翻訳")
                    .font(.body)
                    .foregroundColor(.secondary)
                Picker("", selection: $viewModel.targetLanguage) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: viewModel.targetLanguage) { _ in
                    if viewModel.targetLanguage == viewModel.sourceLanguage {
                        viewModel.sourceLanguage = viewModel.targetLanguage == .japanese ? .english : .japanese
                    }
                    retranslateIfNeeded()
                }
            }

            if viewModel.isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("翻訳中...")
                        .font(.system(size: viewModel.fontSize))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    Text(viewModel.translatedText)
                        .font(.system(size: viewModel.fontSize))
                        .foregroundColor(viewModel.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retranslateIfNeeded() {
        guard !viewModel.originalText.isEmpty, !viewModel.isLoading else { return }
        onTranslate(viewModel.originalText, viewModel.sourceLanguage, viewModel.targetLanguage)
    }

    private var actionButtons: some View {
        HStack {
            Button(action: onSwap) {
                Image(systemName: viewModel.isHorizontalSplit ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("入れ替えて翻訳 (⇧⌘Enter)")
            .disabled(viewModel.isLoading || (viewModel.originalText.isEmpty && viewModel.translatedText.isEmpty))

            Spacer()

            Button("翻訳 (⌘Enter)") {
                onTranslate(viewModel.originalText, viewModel.sourceLanguage, viewModel.targetLanguage)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isLoading || viewModel.originalText.isEmpty)
        }
    }

    private var copyButton: some View {
        HStack {
            Spacer()
            Button("コピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.translatedText, forType: .string)
            }
            .disabled(viewModel.isLoading || viewModel.translatedText.isEmpty)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.isHorizontalSplit {
                HStack(spacing: 12) {
                    originalSection
                    Divider()
                    translatedSection
                }
            } else {
                originalSection
                actionButtons
                Divider()
                translatedSection
            }

            if viewModel.isHorizontalSplit {
                HStack {
                    actionButtons
                    Spacer()
                    copyButton
                }
            } else {
                copyButton
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct TitlebarControlView: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                viewModel.isHorizontalSplit.toggle()
            }) {
                Image(systemName: viewModel.isHorizontalSplit ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(viewModel.isHorizontalSplit ? "縦に分割" : "横に分割")

            HStack(spacing: 4) {
                Text("A")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Slider(value: $viewModel.fontSize, in: 10...40, step: 1)
                    .frame(width: 100)
                Text("A")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text("\(Int(viewModel.fontSize))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
            }
        }
        .padding(.trailing, 8)
    }
}
