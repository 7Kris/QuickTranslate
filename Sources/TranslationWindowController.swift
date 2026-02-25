import AppKit
import SwiftUI

class TranslationWindowController {
    private var window: NSWindow?
    private var viewModel = TranslationViewModel()

    func show(original: String, result: String?, isError: Bool) {
        viewModel.originalText = original
        viewModel.translatedText = result ?? ""
        viewModel.isLoading = result == nil
        viewModel.isError = isError

        if window == nil {
            createWindow()
        }

        positionWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateResult(_ result: String) {
        viewModel.translatedText = result
        viewModel.isLoading = false
    }

    func setError(_ isError: Bool) {
        viewModel.isError = isError
    }

    private func createWindow() {
        let contentView = TranslationView(viewModel: viewModel) { [weak self] in
            self?.close()
        }

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = "QuickTranslate"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

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

    private func close() {
        window?.orderOut(nil)
    }
}

class TranslationViewModel: ObservableObject {
    @Published var originalText: String = ""
    @Published var translatedText: String = ""
    @Published var isLoading: Bool = false
    @Published var isError: Bool = false
}

struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 原文
            VStack(alignment: .leading, spacing: 4) {
                Text("原文")
                    .font(.body)
                    .foregroundColor(.secondary)
                ScrollView {
                    Text(viewModel.originalText)
                        .font(.system(size: 26))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
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
                            .font(.system(size: 26))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        Text(viewModel.translatedText)
                            .font(.system(size: 26))
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

                Button("閉じる") {
                    onClose()
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 480)
    }
}
