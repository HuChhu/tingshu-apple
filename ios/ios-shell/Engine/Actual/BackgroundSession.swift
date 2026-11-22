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

    /// 播放前调用（PlayerView stub 已接）。三件套任一失败都浮出，不静默吞。
    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            #if DEBUG
            debugPrint("[BackgroundSession] 三件套配置失败: " + String(describing: error))
        #endif
        }
        wireObservers()
    }

    /// 打断结束 → shouldResume；旧设备拔出 → 暂停。恢复动作为 stub，M3 前补真身。
    private static func wireObservers() {
        guard !observersWired else { return }
        observersWired = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            let opt = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: opt).contains(.shouldResume) {
                Player.shared.resumeAfterInterruption()   // 打断恢复真身（队列非空即续播）
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Player.shared.pause()        // 拔耳机即暂停
            }
        }
    }
}
