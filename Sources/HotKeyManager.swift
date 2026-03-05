import Carbon
import AppKit
import CoreGraphics

class HotKeyManager {
    private static var eventTap: CFMachPort?
    private static var callback: (() -> Void)?
    private static var lastCommandDTime: Date?
    private static let doubleTapInterval: TimeInterval = 0.4
    private static var waitingForSecondTap = false
    private static var pendingTimer: DispatchWorkItem?
    private static let replayMarker: Int64 = 0x5154_4B59 // "QTKY"
    func register(callback: @escaping () -> Void) {
        HotKeyManager.callback = callback

        // プロンプト付きで権限をチェック（初回のみシステムダイアログが表示される）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        guard trusted else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                // イベントタップが無効化された場合は再有効化
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = HotKeyManager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                return HotKeyManager.handleKeyDown(event: event)
            },
            userInfo: nil
        ) else {
            return
        }

        HotKeyManager.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func handleKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // リプレイされたイベントはそのまま通す
        if event.getIntegerValueField(.eventSourceUserData) == replayMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Command+D のみ検出（keyCode 2 = 'D'、他の修飾キーなし）
        let isCommandOnly = flags.contains(.maskCommand) &&
                            !flags.contains(.maskShift) &&
                            !flags.contains(.maskAlternate) &&
                            !flags.contains(.maskControl)

        guard keyCode == 2 && isCommandOnly else {
            return Unmanaged.passUnretained(event)
        }

        let now = Date()

        if waitingForSecondTap, let lastTime = lastCommandDTime,
           now.timeIntervalSince(lastTime) < doubleTapInterval {
            // ダブルタップ検出
            pendingTimer?.cancel()
            pendingTimer = nil
            waitingForSecondTap = false
            lastCommandDTime = nil

            simulateCopyAndTranslate()

            // 2回目のイベントを消費（Safariに渡さない）
            return nil
        } else {
            // 1回目のタップ：消費してタイマー開始
            pendingTimer?.cancel()
            lastCommandDTime = now
            waitingForSecondTap = true

            let timer = DispatchWorkItem {
                // タイマー切れ：ダブルタップではなかったので元のCommand+Dをリプレイ
                HotKeyManager.waitingForSecondTap = false
                HotKeyManager.lastCommandDTime = nil
                HotKeyManager.replayCommandD()
            }
            pendingTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: timer)

            // 1回目のイベントを消費（リプレイで復元する）
            return nil
        }
    }

    private static func replayCommandD() {
        let source = CGEventSource(stateID: .hidSystemState)

        // 'D' key = keyCode 2
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        // リプレイマーカーを付与して再インターセプトを防止
        keyDown?.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        keyUp?.setIntegerValueField(.eventSourceUserData, value: replayMarker)

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func simulateCopyAndTranslate() {
        // CGEventを使ってCommand+Cを送信し、選択テキストをクリップボードにコピー
        let source = CGEventSource(stateID: .hidSystemState)

        // 'C' key = keyCode 8
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // 0.2秒待ってからクリップボードを読み取り翻訳を実行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            callback?()
        }
    }

    deinit {
        if let tap = HotKeyManager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            HotKeyManager.eventTap = nil
        }
    }
}
