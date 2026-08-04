import Carbon
import AppKit
import CoreGraphics
import os

class HotKeyManager {
    private static let log = Logger(subsystem: "net.kenmaz.QuickTranslate", category: "hotkey")
    private static var eventTap: CFMachPort?
    private static var tapRunLoop: CFRunLoop?
    private static var tapRunLoopSource: CFRunLoopSource?
    private static var callback: (() -> Void)?
    private static var lastCommandCNanos: UInt64?
    // DispatchTime.now().uptimeNanoseconds は単位が常にナノ秒で単調増加 (システム時刻変更の影響を受けない)。
    // CGEvent.timestamp は単位 (ナノ秒 / mach absolute tick) が環境依存なので判定には使わない。
    private static let doubleTapIntervalNanos: UInt64 = 400_000_000
    private static let tapQueue = DispatchQueue(label: "com.quicktranslate.eventtap")
    private static var healthCheckTimer: DispatchSourceTimer?

    func register(callback: @escaping () -> Void) {
        HotKeyManager.callback = callback
        HotKeyManager.requestAccessibilityThenStart()
        HotKeyManager.observeWakeAndUnlock()
    }

    /// アクセシビリティ権限を要求し、許可されたらイベントタップを開始する。
    /// 未許可のまま黙って終了すると「後から権限を付けてもアプリ再起動まで効かない」状態になるため、許可されるまで待つ。
    private static func requestAccessibilityThenStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
            return
        }
        log.notice("accessibility permission not granted; waiting for it")
        waitForAccessibility()
    }

    private static func waitForAccessibility() {
        // 2 回目以降はプロンプトなしで確認する (ダイアログを繰り返し出さないため)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if AXIsProcessTrusted() {
                log.notice("accessibility permission granted; starting event tap")
                startTap()
            } else {
                waitForAccessibility()
            }
        }
    }

    /// スリープ復帰・画面ロック解除・セッション復帰でタップを作り直す。
    /// cgSessionEventTap は復帰後 `CGEvent.tapIsEnabled` が true のままイベントが配信されなくなることがあり、
    /// 再有効化では戻らないため作り直すしかない。
    private static func observeWakeAndUnlock() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                scheduleTapRecreation(reason: name.rawValue)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            scheduleTapRecreation(reason: "com.apple.screenIsUnlocked")
        }
    }

    /// 復帰直後はセッションが落ち着いていないことがあるので少し待ってから作り直す
    private static func scheduleTapRecreation(reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            recreateTap(reason: reason)
        }
    }

    private static func recreateTap(reason: String) {
        guard AXIsProcessTrusted() else {
            log.notice("skip tap recreation (not trusted): \(reason, privacy: .public)")
            return
        }
        log.notice("recreating event tap: \(reason, privacy: .public)")
        teardownTap()
        startTap()
    }

    private static func teardownTap() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoop = tapRunLoop, let source = tapRunLoopSource {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        // CFRunLoopRun から抜けさせてタップ用スレッドを終了させる
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        tapRunLoopSource = nil
        tapRunLoop = nil
    }

    private static func startTap() {
        guard eventTap == nil else { return }

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
                        HotKeyManager.log.notice("event tap disabled (type=\(type.rawValue, privacy: .public)); re-enabling")
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

                    // 判定は単位が保証される自前の単調増加クロックで行う
                    let nowNanos = DispatchTime.now().uptimeNanoseconds
                    let rawEventTimestamp = event.timestamp
                    HotKeyManager.tapQueue.async {
                        HotKeyManager.handleCommandC(nowNanos: nowNanos, rawEventTimestamp: rawEventTimestamp)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            ) else {
                log.error("CGEvent.tapCreate failed")
                return
            }

            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            HotKeyManager.eventTap = tap
            HotKeyManager.tapRunLoopSource = runLoopSource
            HotKeyManager.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            log.notice("event tap created and enabled")
            HotKeyManager.startHealthCheck()
            CFRunLoopRun()
            log.notice("event tap run loop finished")
        }
        thread.name = "com.quicktranslate.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 無効化コールバックが来ないまま停止しているケースからの復帰
    private static func startHealthCheck() {
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            guard let tap = eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.notice("health check: event tap was disabled; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private static func handleCommandC(nowNanos: UInt64, rawEventTimestamp: UInt64) {
        let elapsed = lastCommandCNanos.map { nowNanos >= $0 ? nowNanos - $0 : 0 }
        log.notice("Cmd+C detected (elapsedMs=\(elapsed.map { String($0 / 1_000_000) } ?? "-", privacy: .public), rawEventTimestamp=\(rawEventTimestamp, privacy: .public))")

        if let elapsed, elapsed < doubleTapIntervalNanos {
            // ダブルタップ検出：1回目のCmd+Cでクリップボードが更新されるのを待ってから翻訳実行
            lastCommandCNanos = nil
            log.notice("double tap detected; firing translation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                callback?()
            }
        } else {
            lastCommandCNanos = nowNanos
        }
    }

    deinit {
        HotKeyManager.teardownTap()
    }
}
