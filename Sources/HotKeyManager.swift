import Carbon
import AppKit
import CoreGraphics

class HotKeyManager {
    private static var eventTap: CFMachPort?
    private static var callback: (() -> Void)?
    private static var lastCommandCTime: Date?
    private static let doubleTapInterval: TimeInterval = 0.4
    private static let tapQueue = DispatchQueue(label: "com.quicktranslate.eventtap")

    func register(callback: @escaping () -> Void) {
        HotKeyManager.callback = callback

        // プロンプト付きで権限をチェック（初回のみシステムダイアログが表示される）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        guard trusted else { return }

        // イベントタップを専用バックグラウンドスレッドで実行し、
        // メインスレッドの負荷でHIDパイプラインがブロックされるのを防ぐ
        let thread = Thread {
            let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                    // イベントタップが無効化された場合は再有効化
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = HotKeyManager.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    HotKeyManager.tapQueue.async {
                        HotKeyManager.handleKeyDown(event: event)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            ) else {
                return
            }

            HotKeyManager.eventTap = tap
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.quicktranslate.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func handleKeyDown(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Command+C のみ検出（keyCode 8 = 'C'、他の修飾キーなし）
        let isCommandOnly = flags.contains(.maskCommand) &&
                            !flags.contains(.maskShift) &&
                            !flags.contains(.maskAlternate) &&
                            !flags.contains(.maskControl)

        guard keyCode == 8 && isCommandOnly else {
            return
        }

        let now = Date()

        if let lastTime = lastCommandCTime,
           now.timeIntervalSince(lastTime) < doubleTapInterval {
            // ダブルタップ検出：1回目のCmd+Cでクリップボードが更新されるのを待ってから翻訳実行
            lastCommandCTime = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                callback?()
            }
        } else {
            lastCommandCTime = now
        }
    }

    deinit {
        if let tap = HotKeyManager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            HotKeyManager.eventTap = nil
        }
    }
}
