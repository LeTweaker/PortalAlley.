import Foundation
import PortalCore
import SwiftUI

/// UI state.  The AR controller writes it; SwiftUI reads it.
@MainActor
final class AppModel: ObservableObject {
    @Published var phase: ExperiencePhase = .idle
    @Published var instruction = ""
    @Published var instructionIsWarning = false
    @Published var canConfirm = false
    @Published var muted = false
    @Published var showReplaceOffer = false
    @Published var devPanelVisible = false
    @Published var diagnostics = DiagnosticsSnapshot()
    @Published var fatalMessage: String?
    @Published var assetsReady = false
    @Published var insideView = false

    // Easy Mode placement (v1.2.2)
    @Published var easyMode = true
    @Published var canCreate = false
    @Published var placementMethod = ""
    @Published var placementHint: String?
    @Published var portalOffscreen = false
    @Published var findArrowAngle: Double = 0
    @Published var confirmation: String?
    private var confirmationTask: Task<Void, Never>?

    // v1.3: placed portal controls
    @Published var portalKind = ""            // wall | floor | ceiling
    @Published var canGrow = false
    @Published var canShrink = false
    @Published var canRotate = false
    @Published var portalScaleText = "100%"
    @Published var floorWarning = false
    @Published var classicBoundary = false

    func showConfirmation(_ text: String) {
        confirmation = text
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }

    // developer settings
    @Published var tier: QualityTier = .deviceDefault
    @Published var lidarSupported = false
    @Published var lidarOcclusion = false
    @Published var spillLight = false
    @Published var showARStatistics = false
    @Published private(set) var notes: [String] = []

    private(set) var controller: PortalController?

    func makeController() -> PortalController {
        if let c = controller { return c }
        let c = PortalController(model: self)
        controller = c
        return c
    }

    func note(_ s: String) { notes.append(s) }

    // MARK: intents
    func start() { controller?.start() }
    func restartScan() { controller?.restartScan() }
    func createPortal() { controller?.createPortal() }
    func movePortal() { controller?.movePortal() }
    func findPortal() { controller?.findPortal() }
    func resizePortal(grow: Bool) { controller?.resizePortal(grow: grow) }
    func rotatePortal(clockwise: Bool) { controller?.rotatePortal(clockwise: clockwise) }
    func setClassicBoundary(_ on: Bool) { controller?.setClassicBoundary(on) }
    func setEasyMode(_ on: Bool) { controller?.setEasyMode(on) }
    func confirm() { controller?.confirm() }
    func back() { controller?.back() }
    func reposition() { controller?.reposition() }
    func close() { controller?.close() }
    func toggleInsideView() { controller?.toggleInsideView() }
    func keepWaiting() { controller?.keepWaiting() }
    func placeAgain() { controller?.reposition() }
    func toggleMute() { muted.toggle(); controller?.setMuted(muted) }
    func setTier(_ t: QualityTier) { tier = t; controller?.setTier(t) }
    func setLidar(_ on: Bool) { lidarOcclusion = on; controller?.setLidarOcclusion(on) }
    func setSpill(_ on: Bool) { spillLight = on; controller?.setSpill(on) }
    func setARStats(_ on: Bool) { showARStatistics = on; controller?.setARStatistics(on) }
    func report() -> String { controller?.diagnosticsReport() ?? "" }
}


