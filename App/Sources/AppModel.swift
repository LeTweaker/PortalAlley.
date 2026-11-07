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
    func confirm() { controller?.confirm() }
    func back() { controller?.back() }
    func reposition() { controller?.reposition() }
    func close() { controller?.close() }
    func keepWaiting() { controller?.keepWaiting() }
    func placeAgain() { controller?.reposition() }
    func toggleMute() { muted.toggle(); controller?.setMuted(muted) }
    func setTier(_ t: QualityTier) { tier = t; controller?.setTier(t) }
    func setLidar(_ on: Bool) { lidarOcclusion = on; controller?.setLidarOcclusion(on) }
    func setSpill(_ on: Bool) { spillLight = on; controller?.setSpill(on) }
    func setARStats(_ on: Bool) { showARStatistics = on; controller?.setARStatistics(on) }
    func report() -> String { controller?.diagnosticsReport() ?? "" }
}
