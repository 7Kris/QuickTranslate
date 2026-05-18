import Carbon
import AppKit
import CoreGraphics

class HotKeyManager {
    private static var eventTap: CFMachPort?
    private static var callback: (() -> Void)?
    private static var lastCommandCTimestamp: UInt64?
    // CGEvent.timestamp はナノ秒単位の単調増加クロック。0.4秒 = 4 * 10^8 ns
    private static let doubleTapIntervalNanos: UInt64 = 400_000_000
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

                    // 通常タイピング時のディスパッチ負荷とキュー詰まりによる遅延を避けるため、
                    // Cmd+C 該当時のみキューに投げる（フラグ判定はコールバック内で完結する軽い処理）
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    let isCommandOnly = flags.contains(.maskCommand) &&
                                        !flags.contains(.maskShift) &&
                                        !flags.contains(.maskAlternate) &&
                                        !flags.contains(.maskControl)
                    guard keyCode == 8 && isCommandOnly else {
                        return Unmanaged.passUnretained(event)
                    }

                    // CGEvent.timestamp は単調増加クロック (システム時刻変更の影響を受けない)
                    let timestamp = event.timestamp
                    HotKeyManager.tapQueue.async {
                        HotKeyManager.handleCommandC(timestamp: timestamp)
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

    private static func handleCommandC(timestamp: UInt64) {
        if let lastTime = lastCommandCTimestamp,
           timestamp > lastTime,
           timestamp - lastTime < doubleTapIntervalNanos {
            // ダブルタップ検出：1回目のCmd+Cでクリップボードが更新されるのを待ってから翻訳実行
            lastCommandCTimestamp = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                callback?()
            }
        } else {
            lastCommandCTimestamp = timestamp
        }
    }

    deinit {
        if let tap = HotKeyManager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            HotKeyManager.eventTap = nil
        }
    }
}
