import AppKit
import SwiftUI

class TranslationWindowController {
    private var window: NSWindow?
    private var viewModel = TranslationViewModel()
    var onTranslate: ((String) -> Void)?

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

    func updateResult(_ result: String) {
        viewModel.translatedText = result
        viewModel.isLoading = false
    }

    func setError(_ isError: Bool) {
        viewModel.isError = isError
    }

    private func createWindow() {
        let contentView = TranslationView(viewModel: viewModel, onClose: { [weak self] in
            self?.close()
        }, onTranslate: { [weak self] text in
            self?.onTranslate?(text)
        }, onSwap: { [weak self] in
            self?.swapTexts()
            if let text = self?.viewModel.originalText, !text.isEmpty {
                self?.onTranslate?(text)
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
        let fontSizeView = NSHostingView(rootView: FontSizeControlView(viewModel: viewModel))
        fontSizeView.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = fontSizeView
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

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
    }
}

class TranslationViewModel: ObservableObject {
    private static let fontSizeKey = "TranslationFontSize"
    private static let defaultFontSize: CGFloat = 16

    @Published var originalText: String = ""
    @Published var translatedText: String = ""
    @Published var isLoading: Bool = false
    @Published var isError: Bool = false
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? saved : Self.defaultFontSize
    }
}

struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel
    var onClose: () -> Void
    var onTranslate: (String) -> Void
    var onSwap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 原文
            VStack(alignment: .leading, spacing: 4) {
                Text("原文")
                    .font(.body)
                    .foregroundColor(.secondary)
                TextEditor(text: $viewModel.originalText)
                    .font(.system(size: viewModel.fontSize))
                    .scrollContentBackground(.hidden)
            }
            .frame(maxHeight: .infinity)

            // 入れ替え・翻訳ボタン
            HStack {
                Button(action: onSwap) {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(viewModel.isLoading || (viewModel.originalText.isEmpty && viewModel.translatedText.isEmpty))

                Spacer()

                Button("翻訳") {
                    onTranslate(viewModel.originalText)
                }
                .disabled(viewModel.isLoading || viewModel.originalText.isEmpty)
            }

            Divider()

            // 翻訳結果
            VStack(alignment: .leading, spacing: 4) {
                Text("翻訳")
                    .font(.body)
                    .foregroundColor(.secondary)

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
            .frame(maxHeight: .infinity)

            // ボタン
            HStack {
                Spacer()
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.translatedText, forType: .string)
                }
                .disabled(viewModel.isLoading || viewModel.translatedText.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct FontSizeControlView: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
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
        .padding(.trailing, 8)
    }
}
