import PortalCore
import SwiftUI
import UIKit

/// Hidden diagnostics (three-finger tap anywhere, or long-press the
/// instruction pill for 1.5 s).  Everything shown is measured on the device.
struct DeveloperPanel: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    var body: some View {
        let d = model.diagnostics
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostics").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("up \(d.uptime)").font(.system(size: 11)).opacity(0.7)
                Button { model.devPanelVisible = false } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Hide diagnostics")
            }
            Group {
                row("Frame", String(format: "%.1f fps · mean %.2f ms · p95 %.2f ms · max %.1f ms", d.fps, d.meanMs, d.p95Ms, d.maxMs))
                row("Budget", String(format: "%.1f%% of frames over 16.7 ms (+10%%)", d.overBudgetPct))
                row("Memory", String(format: "%.0f MB (launch %.0f MB) · thermal %@", d.memoryMB, d.memoryStartMB, d.thermal))
                row("Tracking", d.tracking)
                row("Anchor", "ARKit corrections \(d.anchorCorrections), max \(String(format: "%.1f", d.maxCorrectionCm)) cm · app writes after lock \(d.appWritesAfterLock)")
                row("Camera", "portal space \(d.cameraLocal)")
                row("Scene", "\(d.triangles) tris · \(d.lights) lights · tier \(d.tier)")
                row("LiDAR", "\(d.lidar) · \(d.occluderTriangles) occluder tris")
                ForEach(d.shaderIssues, id: \.self) { row("Shader", $0) }
                ForEach(d.notes, id: \.self) { row("Note", $0) }
            }
            Divider().background(Color.white.opacity(0.3))
            Picker("Quality", selection: Binding(get: { model.tier }, set: { model.setTier($0) })) {
                Text("High").tag(QualityTier.high)
                Text("Low").tag(QualityTier.low)
            }
            .pickerStyle(.segmented)
            if model.lidarSupported {
                Toggle("LiDAR occlusion (room side only)", isOn: Binding(get: { model.lidarOcclusion }, set: { model.setLidar($0) }))
            } else {
                Text("LiDAR occlusion: needs a LiDAR iPhone").font(.system(size: 12)).opacity(0.7)
            }
            Toggle("Floor light spill (simulated)", isOn: Binding(get: { model.spillLight }, set: { model.setSpill($0) }))
            Toggle("ARView statistics overlay", isOn: Binding(get: { model.showARStatistics }, set: { model.setARStats($0) }))
            Button(copied ? "Copied" : "Copy report + soak log") {
                UIPasteboard.general.string = model.report()
                copied = true
            }
            .buttonStyle(.bordered)
        }
        .font(.system(size: 12))
        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.78, blue: 0.9)))
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).fontWeight(.semibold).frame(width: 62, alignment: .leading)
            Text(v).fixedSize(horizontal: false, vertical: true)
        }
    }
}
