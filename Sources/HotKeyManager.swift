import Carbon
import AppKit
import CoreGraphics
import os

class HotKeyManager {
    private static let log = Logger(subsystem: "net.kenmaz.QuickTranslate", category: "hotkey")

    /// タップの生成/破棄は main スレッド・タップ用スレッド・tapQueue の 3 者から触るので、必ずこのロック下で扱う
    private static let stateLock = NSLock()
    private static var eventTap: CFMachPort?
    private static var tapRunLoop: CFRunLoop?
    private static var tapRunLoopSource: CFRunLoopSource?
    private static var healthCheckTimer: DispatchSourceTimer?
    private static var isStarting = false
    /// タップの世代。teardown / start のたびに進める。生成中のタップは公開前に自分の世代を確認し、
    /// 古くなっていたら有効化せず破棄する (作り直しが重なったときの二重タップ防止)
    private static var generation: UInt64 = 0
    private static var startRetryCount = 0
    private static let maxStartRetryCount = 10

    private static var callback: (() -> Void)?
    private static var lastCommandCNanos: UInt64?
    private static var lastRawEventTimestamp: UInt64?
    /// main スレッドからのみ触る (作り直し要求のコアレス用)
    private static var pendingRecreation: DispatchWorkItem?
    // DispatchTime.now().uptimeNanoseconds は単位が常にナノ秒で単調増加 (システム時刻変更の影響を受けない)。
    // CGEvent.timestamp は単位 (ナノ秒 / mach absolute tick) が環境依存なので判定には使わない。
    private static let doubleTapIntervalNanos: UInt64 = 400_000_000
    private static let tapQueue = DispatchQueue(label: "com.quicktranslate.eventtap")

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

    /// 復帰直後はセッションが落ち着いていないことがあるので少し待ってから作り直す。
    /// 1 回の復帰で didWake / screensDidWake / screenIsUnlocked などが相次いで飛んでくるため、
    /// 先行する予約はキャンセルして最後の 1 件だけを実行する。
    private static func scheduleTapRecreation(reason: String) {
        pendingRecreation?.cancel()
        let work = DispatchWorkItem { recreateTap(reason: reason) }
        pendingRecreation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
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
        stateLock.lock()
        generation &+= 1  // 生成中のタップがあれば公開させずに破棄させる
        isStarting = false
        let tap = eventTap
        let runLoop = tapRunLoop
        let source = tapRunLoopSource
        let timer = healthCheckTimer
        eventTap = nil
        tapRunLoop = nil
        tapRunLoopSource = nil
        healthCheckTimer = nil
        stateLock.unlock()

        timer?.cancel()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoop, let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        // CFRunLoopRun から抜けさせてタップ用スレッドを終了させる
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private static func startTap() {
        stateLock.lock()
        // 生成はバックグラウンドスレッドで走るので、「生成中」も含めて弾かないと二重にタップができる
        guard eventTap == nil, !isStarting else {
            stateLock.unlock()
            return
        }
        generation &+= 1
        let myGeneration = generation
        isStarting = true
        stateLock.unlock()

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
                    // イベントタップが無効化された場合は再有効化。
                    // 有効化前のタップは必ず破棄しているので、コールバックが走るのは常に現行のタップ
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        HotKeyManager.log.notice("event tap disabled (type=\(type.rawValue, privacy: .public)); re-enabling")
                        HotKeyManager.stateLock.lock()
                        let current = HotKeyManager.eventTap
                        HotKeyManager.stateLock.unlock()
                        if let current {
                            CGEvent.tapEnable(tap: current, enable: true)
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
                stateLock.lock()
                let stale = myGeneration != generation
                if !stale { isStarting = false }
                stateLock.unlock()
                if !stale { scheduleStartRetry() }
                return
            }

            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

            stateLock.lock()
            guard myGeneration == generation else {
                stateLock.unlock()
                // 自分より新しい作り直しが走っている。有効化せずに捨てる (二重タップ防止)
                CFMachPortInvalidate(tap)
                log.notice("discarding stale event tap")
                return
            }
            eventTap = tap
            tapRunLoopSource = runLoopSource
            tapRunLoop = CFRunLoopGetCurrent()
            isStarting = false
            startRetryCount = 0
            stateLock.unlock()

            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            log.notice("event tap created and enabled")
            startHealthCheck(generation: myGeneration)
            CFRunLoopRun()
            log.notice("event tap run loop finished")
        }
        thread.name = "com.quicktranslate.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 権限付与直後などに tapCreate が一時的に失敗することがある。
    /// 復帰通知が来るまで無反応になってしまうので、少し待って作り直す。
    private static func scheduleStartRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard AXIsProcessTrusted() else { return }
            stateLock.lock()
            let giveUp = startRetryCount >= maxStartRetryCount
            if !giveUp { startRetryCount += 1 }
            let attempt = startRetryCount
            stateLock.unlock()
            guard !giveUp else {
                log.error("giving up event tap creation after \(maxStartRetryCount, privacy: .public) retries")
                return
            }
            log.notice("retrying event tap creation (attempt=\(attempt, privacy: .public))")
            startTap()
        }
    }

    /// 無効化コールバックが来ないまま無効になっているケースからの復帰。
    /// 「enabled のままイベントだけ来なくなる」状態はここでは検知できない (それは復帰通知での作り直しで拾う)。
    private static func startHealthCheck(generation myGeneration: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            stateLock.lock()
            let tap = myGeneration == generation ? eventTap : nil
            stateLock.unlock()
            guard let tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.notice("health check: event tap was disabled; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.resume()

        // 登録の直前に teardown が走っていた場合、このタイマーは誰にも止められなくなるのでここで捨てる
        stateLock.lock()
        let stale = myGeneration != generation
        if !stale {
            healthCheckTimer?.cancel()
            healthCheckTimer = timer
        }
        stateLock.unlock()
        if stale {
            timer.cancel()
        }
    }

    private static func handleCommandC(nowNanos: UInt64, rawEventTimestamp: UInt64) {
        // 同じ物理イベントが二重配信されたときにダブルタップと誤判定しないための保険
        if rawEventTimestamp != 0, lastRawEventTimestamp == rawEventTimestamp {
            log.notice("ignoring duplicate Cmd+C delivery (rawEventTimestamp=\(rawEventTimestamp, privacy: .public))")
            return
        }
        lastRawEventTimestamp = rawEventTimestamp

        let elapsed = lastCommandCNanos.map { nowNanos > $0 ? nowNanos - $0 : 0 }
        log.notice("Cmd+C detected (elapsedMs=\(elapsed.map { String($0 / 1_000_000) } ?? "-", privacy: .public), rawEventTimestamp=\(rawEventTimestamp, privacy: .public))")

        if let elapsed, elapsed > 0, elapsed < doubleTapIntervalNanos {
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
