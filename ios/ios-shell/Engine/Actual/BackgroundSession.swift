import Foundation
import AVFoundation

/// 触点 5/5：后台会话 = 播放三件套 + 打断/拔耳机恢复（iOS席纪律）。
/// ① category .playback（漏设 = 后台必静音的头号死因）
/// ② setActive(true)
/// ③ Info.plist UIBackgroundModes=[audio]（本工程 ios-shell/Info.plist 已写入）
/// 原 AudioSessionController 占位并入本文件，保持 Actual 恰 5 文件不变量。
@MainActor
enum BackgroundSession {
    private static var observersWired = false

    /// 最近一次激活失败原因（Player 失败时拼进 errorText，用户能看到「没声音」的真实原因）
    private(set) static var lastActivationError: String?

    /// 打断前是否真的在出声（被打断时用户正在听，结束才自动恢复；用户手停的就别替他开）
    private static var interruptionBeganActive = false

    /// 播放前调用。三件套任一失败都浮出，不静默吞。
    /// force=false：已激活且 category 正确时直接返回（每集都 setActive(true) 会被系统
    /// 记一次多余的激活，锁屏播放常常因此被系统当成重复激活而丢弃 audio session）。
    /// force=true：回前台 / 打断结束 / 拔耳机后强刷，覆盖「后台期间被别人抢走」的情况。
    static func activateForPlayback(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        let alreadyOk = session.category == .playback && session.isOtherAudioPlaying == false
        if !force && alreadyOk && sessionKeyActive {
            wireObservers()
            return
        }
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            sessionKeyActive = true
            lastActivationError = nil
        } catch {
            sessionKeyActive = false
            lastActivationError = String(describing: error)
            #if DEBUG
            debugPrint("[BackgroundSession] 三件套配置失败: " + String(describing: error))
            #endif
        }
        wireObservers()
    }

    /// 本进程内最近一次 setActive(true) 是否成功（系统没有「当前是否激活」的查询接口，
    /// 只能自己记账；deactivate 路径清账）
    private static var sessionKeyActive = false

    /// 主动交还焦点（停止播放 / 用户明确不听了）
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            #if DEBUG
            debugPrint("[BackgroundSession] deactivate 失败: " + String(describing: error))
            #endif
        }
        sessionKeyActive = false
    }

    /// 打断 began → 暂停并落进度；ended + shouldResume → 重激活后续播。
/// 旧设备拔出 → 无其它输出时暂停；新设备接入 / 类别变化 → 重激活。
    private static func wireObservers() {
        guard !observersWired else { return }
        observersWired = true

        // 打断：began 必须停下并落进度（来电/闹钟/Siri/连上车载），
        // ended 只认 shouldResume（系统说可以恢复才恢复；没给就别自作主张出声）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                Task { @MainActor in
                    interruptionBeganActive = Player.shared.state == .playing
                    Player.shared.pauseForRouteChange()
                }
            case .ended:
                let opt = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let canResume = AVAudioSession.InterruptionOptions(rawValue: opt).contains(.shouldResume)
                Task { @MainActor in
                    // 系统接管后解锁期必须重新激活，否则 play() 无声
                    activateForPlayback(force: true)
                    if canResume && interruptionBeganActive {
                        Player.shared.resumeAfterInterruption()
                    }
                    interruptionBeganActive = false
                }
            @unknown default:
                break
            }
        }

        // 耳机拔出的三条真实路径：
        // ①有线耳机拔掉 ②蓝牙耳机断开/关机 ③车上拔线 —— 全是 .oldDeviceUnavailable
        // 唯一例外：拔的同时已经有新的输出设备接手（带上车、切换蓝牙），此时不该停
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let session = AVAudioSession.sharedInstance()
            Task { @MainActor in
                switch reason {
                case .oldDeviceUnavailable:
                    let stillHasOutput = session.currentRoute.outputs.contains { out in
                        out.portType != .builtInSpeaker
                    }
                    if !stillHasOutput { Player.shared.pauseForRouteChange() }
                case .newDeviceAvailable:
                    // 插上耳机/连上蓝牙：会话被系统重配过，重激活，否则插耳机后仍是听筒/无声
                    if Player.shared.state == .playing || Player.shared.state == .paused {
                        activateForPlayback(force: true)
                    }
                case .categoryChange, .override:
                    if Player.shared.state == .playing { activateForPlayback(force: true) }
                case .routeConfigurationChange:
                    if Player.shared.state == .playing { activateForPlayback(force: true) }
                default:
                    break
                }
            }
        }
    }
}
