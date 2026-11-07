import Foundation
import PortalCore
import UIKit

struct DiagnosticsSnapshot: Equatable {
    var fps: Double = 0
    var meanMs: Double = 0
    var p95Ms: Double = 0
    var maxMs: Double = 0
    var overBudgetPct: Double = 0
    var memoryMB: Double = 0
    var memoryStartMB: Double = 0
    var thermal: String = "nominal"
    var tracking: String = "-"
    var trackingSince: String = ""
    var anchorCorrections: Int = 0
    var maxCorrectionCm: Double = 0
    var appWritesAfterLock: Int = 0
    var cameraLocal: String = "-"
    var tier: String = "-"
    var lights: Int = 0
    var triangles: Int = 0
    var lidar: String = "-"
    var occluderTriangles: Int = 0
    var shaderIssues: [String] = []
    var uptime: String = "0:00"
    var notes: [String] = []
}

/// Measured runtime statistics (frame intervals from RealityKit's update loop,
/// physical memory footprint, thermal state) plus a soak log the tester can copy.
@MainActor
final class Diagnostics {
    private(set) var stats = FrameStats(capacity: 600)
    private var soakStats = FrameStats(capacity: 1200)
    private let start = Date()
    private var lastSoak = Date()
    private(set) var soakLog: [String] = []
    let memoryAtLaunch: Double

    init() { memoryAtLaunch = Diagnostics.memoryFootprintMB() }

    func frame(intervalSeconds dt: Double) {
        stats.add(intervalMs: dt * 1000)
        soakStats.add(intervalMs: dt * 1000)
    }

    func resetStats() { stats.reset() }

    var uptime: TimeInterval { Date().timeIntervalSince(start) }

    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func thermalString(_ s: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Appends one line every 10 s while the portal is open.
    func soakTick(tracking: String, corrections: Int, maxCorrectionCm: Double, tier: String) {
        guard Date().timeIntervalSince(lastSoak) >= 10 else { return }
        lastSoak = Date()
        let s = soakStats.summary()
        soakStats.reset()
        let t = Int(uptime)
        soakLog.append(String(format: "%02d:%02d fps %.1f p95 %.1fms max %.1fms >budget %.1f%% mem %.0fMB thermal %@ track %@ corr %d (max %.1fcm) tier %@",
                              t / 60, t % 60, s.fps, s.p95Ms, s.maxMs, s.overBudget * 100, Self.memoryFootprintMB(),
                              Self.thermalString(), tracking, corrections, maxCorrectionCm, tier))
        if soakLog.count > 400 { soakLog.removeFirst() }
    }

    func reportText(snapshot: DiagnosticsSnapshot) -> String {
        var lines = [
            "PortalAlley diagnostics",
            "device \(Self.deviceModel()) iOS \(UIDevice.current.systemVersion)",
            String(format: "fps %.1f mean %.2fms p95 %.2fms max %.1fms over-budget %.1f%%", snapshot.fps, snapshot.meanMs, snapshot.p95Ms, snapshot.maxMs, snapshot.overBudgetPct),
            String(format: "memory %.0f MB (launch %.0f MB) thermal %@", snapshot.memoryMB, snapshot.memoryStartMB, snapshot.thermal),
            "tracking \(snapshot.tracking) corrections \(snapshot.anchorCorrections) max \(String(format: "%.1f", snapshot.maxCorrectionCm)) cm app writes after lock \(snapshot.appWritesAfterLock)",
            "tier \(snapshot.tier) lights \(snapshot.lights) tris \(snapshot.triangles) lidar \(snapshot.lidar) occluder tris \(snapshot.occluderTriangles)",
        ]
        lines += snapshot.shaderIssues.map { "shader fallback: \($0)" }
        lines += snapshot.notes
        lines.append("--- soak log (10 s intervals) ---")
        lines += soakLog
        return lines.joined(separator: "\n")
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
