import ARKit
import Combine
import Foundation
import PortalCore
import RealityKit
import UIKit

/// Owns the ARView and runs the experience:
/// scan -> preview -> pin/adjust -> confirm -> anchored doorway -> explore.
///
/// Anchoring rules (see docs/RENDERING_AND_ANCHORING.md):
/// * Before confirmation the preview follows ARKit raycasts against detected
///   horizontal planes (display-smoothed; this is UI, not the doorway).
/// * On confirmation ONE ARAnchor is added and the doorway is parented to an
///   AnchorEntity for it.  The app never writes the doorway's transform again;
///   ARKit may still refine the anchor (logged as "corrections").
/// * The camera pose is used exactly as ARKit reports it (no smoothing/delay).
@MainActor
final class PortalController: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
    let arView: ARView
    private weak var model: AppModel?

    // assets & scene
    private var assets: PortalAssets?
    private var rig: PortalRig?
    private var preview: PreviewRig?
    private var audio: PortalAudio?
    private let occlusion = SceneOcclusion()
    private let diagnostics = Diagnostics()
    private var updateSub: Cancellable?

    // logic (PortalCore)
    private var machine = ExperienceStateMachine()
    private var tracking = TrackingPolicy()
    private var scanRecovery = ScanRecoveryPolicy()
    private var boundary = BoundaryPolicy()
    private let rules = PlacementRules()
    private var dims = PortalDimensions()

    // tracking inputs (from the latest ARFrame; the frame itself is not retained)
    private var quality: TrackingQuality = .initializing
    private var qualityText = "initializing"
    private var lowLight = false
    private var sessionRunning = false

    // placement
    private var candidate: (position: SIMD3<Float>, yaw: Float, plane: PlaneKind, extent: SIMD2<Float>)?
    private var displayPreviewPos: SIMD3<Float>?
    private var pinned: (position: SIMD3<Float>, yaw: Float, plane: PlaneKind, extent: SIMD2<Float>)?
    private var currentIssue: PlacementIssue?
    private var lastRaycast: TimeInterval = 0
    private var lastObstruction: (time: TimeInterval, count: Int?) = (0, nil)

    // anchored doorway
    private var portalAnchor: ARAnchor?
    private var anchorEntity: AnchorEntity?
    private var lastAnchorTranslation: SIMD3<Float>?
    private var corrections = 0
    private var maxCorrection: Float = 0
    private var appWritesAfterLock = 0          // stays 0 by construction; shown for verification
    private var phaseStart: TimeInterval = 0
    private var displayAperture: Float = 0
    private var displayFrame: Float = 0
    private var currentLook = PortalLook.closed
    private var lastCameraLocal = SIMD3<Float>(repeating: 0)
    private var warmupAnchor: AnchorEntity?
    private var interrupted = false
    private var insideOffset: SIMD3<Float>?
    private var placementPanOffset: SIMD3<Float>?

    // settings
    private(set) var tier: QualityTier = .deviceDefault
    private var muted = false
    private var lidarOcclusion = false
    let lidarSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    init(model: AppModel) {
        self.model = model
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        lidarOcclusion = lidarSupported && tier == .high
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)
        arView.renderOptions.insert(.disableGroundingShadows)   // own contact shadow
        arView.renderOptions.insert(.disablePersonOcclusion)    // would erase the destination
        arView.renderOptions.insert(.disableFaceMesh)
        arView.environment.sceneUnderstanding.options = []      // see SceneOcclusion for why
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        installGestures()
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(dt: event.deltaTime)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        model.lidarSupported = lidarSupported
        model.lidarOcclusion = lidarOcclusion
        model.tier = tier
        Task { await prepareAssets() }
    }

    // MARK: - assets (loaded while the user is on the start screen / scanning)

    private func prepareAssets() async {
        do {
            PortalAudio.configureSession()
            let a = try PortalAssets(tier: tier)
            assets = a
            dims = a.dims
            occlusion.dims = a.dims
            try await a.loadMeshes()
            try await a.preloadTextures()
            let r = try PortalRig(assets: a)
            r.applyTier(tier)
            r.root.addChild(occlusion.root)
            rig = r
            let p = try PreviewRig(assets: a)
            preview = p
            arView.scene.addAnchor(p.anchor)
            audio = PortalAudio(baseURL: a.baseURL)
            model?.assetsReady = true
        } catch {
            model?.fatalMessage = "Couldn't load the portal: \(error.localizedDescription)"
        }
    }

    /// Render the rig once at microscopic scale so RealityKit compiles every
    /// pipeline (custom shaders, transparency, occlusion) before the user
    /// opens the doorway.  Called when scanning starts.
    private func warmUpRenderer() {
        guard let rig, warmupAnchor == nil, rig.root.parent == nil else { return }
        var m = arView.cameraTransform.matrix
        m.columns.3 += m.columns.2 * -1.0
        let a = AnchorEntity(world: m)
        rig.root.scale = SIMD3(repeating: 0.0005)
        rig.apply(PortalLook(frameOpacity: 0.5, edgeIntensity: 1, edgeSweep: 0.5, seamIntensity: 1, apertureOpen: 0.5, veil: 0.5),
                  worldVisible: true, interiorVisible: true)
        a.addChild(rig.root)
        arView.scene.addAnchor(a)
        warmupAnchor = a
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, let rig = self.rig, let wa = self.warmupAnchor, wa === a else { return }
            if rig.root.parent === wa { rig.root.removeFromParent() }
            rig.root.scale = SIMD3(repeating: 1)
            rig.root.transform = Transform()          // identity: portal space == anchor space
            wa.removeFromParent()
            self.warmupAnchor = nil
        }
    }

    // MARK: - session

    func runSession(resetTracking: Bool = false) {
        guard ARWorldTrackingConfiguration.isSupported else {
            model?.fatalMessage = "This device doesn't support world tracking."
            return
        }
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        cfg.environmentTexturing = .automatic          // lights the doorway with the room
        cfg.isLightEstimationEnabled = true
        cfg.initialWorldMap = nil
        if lidarSupported && lidarOcclusion {
            cfg.sceneReconstruction = .mesh
        }
        // Keep a placed doorway on quality changes. Fresh placement scans
        // explicitly discard the previous map rather than waiting to recover it.
        let options: ARSession.RunOptions = resetTracking ? [.resetTracking, .removeExistingAnchors] : []
        arView.session.run(cfg, options: options)
        sessionRunning = true
        occlusion.enabled = lidarSupported && lidarOcclusion
        applyContentScale()
    }

    private func applyContentScale() {
        let native = arView.window?.screen.nativeScale ?? 3
        arView.contentScaleFactor = tier.contentScale ?? native
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state = frame.camera.trackingState
        let ambient = frame.lightEstimate?.ambientIntensity ?? 1000
        MainActor.assumeIsolated {
            self.ingest(state, ambientLux: ambient)
        }
    }

    private func ingest(_ state: ARCamera.TrackingState, ambientLux: CGFloat) {
        lowLight = ambientLux < 120
        switch state {
        case .normal: quality = .normal; qualityText = "normal"
        case .notAvailable: quality = .notAvailable; qualityText = "not available"
        case .limited(let r):
            switch r {
            case .initializing: quality = .initializing; qualityText = "limited: initializing"
            case .relocalizing: quality = .relocalizing; qualityText = "limited: relocalizing"
            case .excessiveMotion: quality = .excessiveMotion; qualityText = "limited: excessive motion"
            case .insufficientFeatures: quality = .insufficientFeatures; qualityText = "limited: insufficient features"
            @unknown default: quality = .initializing; qualityText = "limited: unknown"
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let updates = anchors.map { ($0.identifier, $0.transform, $0 is ARMeshAnchor) }
        MainActor.assumeIsolated {
            for (id, t, isMesh) in updates {
                if isMesh { self.occlusion.markDirty(id); continue }
                guard id == self.portalAnchor?.identifier else { continue }
                // ARKit-driven correction of the locked doorway (not app positioning)
                let p = PortalMath.translation(t)
                if let last = self.lastAnchorTranslation {
                    let d = simd_distance(p, last)
                    if d > 0.0005 {
                        self.corrections += 1
                        self.maxCorrection = max(self.maxCorrection, d)
                    }
                }
                self.lastAnchorTranslation = p
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        MainActor.assumeIsolated { ids.forEach { self.occlusion.markDirty($0) } }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.map(\.identifier)
        MainActor.assumeIsolated {
            for id in ids {
                self.occlusion.remove(id)
                if id == self.portalAnchor?.identifier {
                    // ARKit removed our anchor (rare). Do not silently re-place.
                    self.model?.showReplaceOffer = true
                }
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.interrupted = true
            self.boundary.suspendCrossing()
            self.model?.instruction = "Paused"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.interrupted = false
            if self.portalAnchor == nil && self.machine.phase != .idle {
                self.beginFreshScan(resetRecoveryBudget: true)
                return
            }
            // Keep the map and the anchor; require stable tracking before trusting it again.
            self.tracking.noteInterruption(now: CACurrentMediaTime())
            self.boundary.suspendCrossing()
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        MainActor.assumeIsolated { self.portalAnchor != nil && self.machine.doorwayAnchored }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message: String
        if let e = error as? ARError, e.code == .cameraUnauthorized {
            message = "Camera access is off. Enable it in Settings > Privacy > Camera."
        } else {
            message = "AR session stopped: \(error.localizedDescription)"
        }
        MainActor.assumeIsolated {
            self.sessionRunning = false
            self.model?.fatalMessage = message
        }
    }

    // MARK: - user actions

    func start() {
        guard model?.assetsReady == true else { return }
        beginFreshScan(resetRecoveryBudget: true)
    }

    func restartScan() {
        guard !machine.doorwayAnchored else { return }
        beginFreshScan(resetRecoveryBudget: true)
    }

    private func beginFreshScan(resetRecoveryBudget: Bool) {
        guard model?.assetsReady == true, portalAnchor == nil else { return }
        preview?.hide()
        if let warmup = warmupAnchor {
            if rig?.root.parent === warmup { rig?.root.removeFromParent() }
            rig?.root.transform = Transform()
            warmup.removeFromParent()
            warmupAnchor = nil
        }
        candidate = nil
        pinned = nil
        placementPanOffset = nil
        currentIssue = nil
        displayPreviewPos = nil
        lastRaycast = 0
        lastObstruction = (0, nil)
        occlusion.reset()
        tracking = TrackingPolicy()
        boundary = BoundaryPolicy()
        quality = .initializing
        qualityText = "initializing (fresh scan)"
        interrupted = false
        if resetRecoveryBudget { scanRecovery = ScanRecoveryPolicy() }
        machine = ExperienceStateMachine()
        machine.handle(.start)
        model?.fatalMessage = nil
        model?.showReplaceOffer = false
        model?.canConfirm = false
        runSession(resetTracking: true)
        if let preview {
            preview.anchor.removeFromParent()
            arView.scene.addAnchor(preview.anchor)
        }
        setInstruction("Move your phone slowly to scan the wall", warning: false)
        publishPhase()
        warmUpRenderer()
    }

    func tap() {
        guard machine.phase == .aiming, let c = candidate, currentIssue == nil else { return }
        pinned = c
        machine.handle(.tap)
        publishPhase()
    }

    func confirm() {
        guard machine.phase == .adjusting, currentIssue == nil, let p = pinned, let rig, warmupAnchor == nil else { return }
        guard machine.handle(.confirm) else { return }
        preview?.hide()
        let m = PortalMath.transform(position: p.position, yaw: p.yaw)
        let anchor = ARAnchor(name: "PortalDoorway", transform: m)
        arView.session.add(anchor: anchor)
        let ae = AnchorEntity(anchor: anchor)
        rig.root.transform = Transform()        // identity: portal space == anchor space
        ae.addChild(rig.root)
        arView.scene.addAnchor(ae)
        portalAnchor = anchor
        anchorEntity = ae
        lastAnchorTranslation = PortalMath.translation(m)
        corrections = 0
        maxCorrection = 0
        appWritesAfterLock = 0
        occlusion.reset()
        boundary = BoundaryPolicy()
        phaseStart = CACurrentMediaTime()
        displayAperture = 1
        displayFrame = 1
        diagnostics.resetStats()
        audio?.start(ambient: rig.ambientEmitter, hum: rig.humEmitter)
        audio?.playOpen(on: rig.humEmitter, muted: muted)
        publishPhase()
    }

    func back() {
        machine.handle(.back)
        pinned = nil
        publishPhase()
    }

    func reposition() {
        removeDoorway()
        beginFreshScan(resetRecoveryBudget: true)
    }

    func close() {
        if machine.doorwayAnchored {
            if machine.handle(.close) {
                phaseStart = CACurrentMediaTime()
                if let rig { audio?.playClose(on: rig.humEmitter, muted: muted) }
            }
        } else {
            machine.handle(.close)
            preview?.hide()
            pauseSession()
        }
        publishPhase()
    }

    func keepWaiting() { model?.showReplaceOffer = false }

    func setMuted(_ m: Bool) { muted = m }

    /// View the inside of a wall-mounted portal without physically crossing a
    /// solid wall. Translate only the destination to an equivalent camera view;
    /// the placed doorway's world anchor is never modified.
    func toggleInsideView() {
        guard machine.phase == .open, let ae = anchorEntity, let rig else { return }
        if insideOffset != nil {
            insideOffset = nil
            rig.setDestinationOffset(.zero)
            boundary = BoundaryPolicy()
            model?.insideView = false
            return
        }
        guard quality == .normal && !interrupted else { return }
        let local = PortalMath.toPortalSpace(PortalMath.translation(arView.cameraTransform.matrix),
                                             portal: ae.transformMatrix(relativeTo: nil))
        let offset = PortalMath.interiorViewOffset(cameraLocal: local)
        let target = local - offset
        insideOffset = offset
        rig.setDestinationOffset(offset)
        boundary.enterInside(cameraLocal: target)
        model?.insideView = true
    }

    func setTier(_ t: QualityTier) {
        tier = t
        rig?.applyTier(t)
        applyContentScale()
        if t == .low && lidarOcclusion { setLidarOcclusion(false) }
    }

    func setLidarOcclusion(_ on: Bool) {
        guard lidarSupported else { return }
        lidarOcclusion = on
        model?.lidarOcclusion = on
        if !on { occlusion.reset() }
        if sessionRunning { runSession() }       // same session, no reset: keeps tracking + anchors
    }

    func setSpill(_ on: Bool) { rig?.setSpill(on) }

    func setARStatistics(_ on: Bool) {
        if on { arView.debugOptions.insert(.showStatistics) } else { arView.debugOptions.remove(.showStatistics) }
    }

    func diagnosticsReport() -> String {
        diagnostics.reportText(snapshot: model?.diagnostics ?? DiagnosticsSnapshot())
    }

    @objc nonisolated private func thermalChanged() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let s = ProcessInfo.processInfo.thermalState
            if (s == .serious || s == .critical) && self.tier == .high {
                self.setTier(.low)
                self.model?.tier = .low
                self.model?.note("Thermal state \(Diagnostics.thermalString(s)): switched to low quality tier")
            }
        }
    }

    private func removeDoorway() {
        audio?.stop()
        insideOffset = nil
        model?.insideView = false
        rig?.setDestinationOffset(.zero)
        boundary = BoundaryPolicy()
        rig?.root.removeFromParent()
        anchorEntity?.removeFromParent()
        if let a = portalAnchor { arView.session.remove(anchor: a) }
        portalAnchor = nil
        anchorEntity = nil
        lastAnchorTranslation = nil
        pinned = nil
        occlusion.reset()
        tracking = TrackingPolicy()
    }

    private func pauseSession() {
        arView.session.pause()
        sessionRunning = false
    }

    // MARK: - per-frame

    private func update(dt: TimeInterval) {
        diagnostics.frame(intervalSeconds: dt)
        let now = CACurrentMediaTime()
        if sessionRunning && machine.phase != .idle &&
           scanRecovery.shouldRestart(quality, hasDoorway: portalAnchor != nil, now: now) {
            model?.note("Restarted an unplaced scan stuck relocalizing")
            beginFreshScan(resetRecoveryBudget: false)
            return
        }
        let decision = tracking.update(quality, lowLight: lowLight, now: now)
        let usable = quality == .normal
        if machine.handle(.trackingUsable(usable)) { publishPhase() }

        switch machine.phase {
        case .scanning:
            preview?.hide()
            let scanMessage = quality == .relocalizing ? "Recovering camera tracking - tap Restart scan if needed" :
                (quality == .normal ? "Point at the wall where the opening should be" : (decision.message ?? "Move your phone slowly to scan the wall"))
            setInstruction(scanMessage, warning: false)
        case .aiming:
            updateAiming(now: now)
        case .adjusting:
            updateAdjusting()
        case .opening, .open, .closing:
            updatePortal(dt: Float(dt), now: now, decision: decision)
        case .idle:
            break
        }
        publishDiagnostics(now: now)
    }

    private func planeKind(_ p: ARPlaneAnchor) -> PlaneKind {
        guard ARPlaneAnchor.isClassificationSupported else { return .classificationUnsupported }
        switch p.classification {
        case .floor: return .floor
        case .table: return .table
        case .seat: return .seat
        case .ceiling: return .ceiling
        case .wall: return .wall
        case .door: return .door
        case .window: return .window
        default: return .unclassified
        }
    }

    private func lowestHorizontalPlaneY() -> Float? {
        arView.session.currentFrame?.anchors
            .compactMap { $0 as? ARPlaneAnchor }
            // Only confirmed floors provide a height reference. A stray lower
            // unclassified plane must not trap the user in "not furniture".
            .filter { $0.alignment == .horizontal && $0.classification == .floor }
            .map { $0.transform.columns.3.y }
            .min()
    }

    /// LiDAR clear-area check: reconstructed points inside the doorway volume.
    private func obstructionCount(for transform: simd_float4x4, now: TimeInterval) -> Int? {
        guard lidarSupported, lidarOcclusion else { return nil }
        if now - lastObstruction.time < 0.25 { return lastObstruction.count }
        guard let anchors = arView.session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }) else { return nil }
        let origin = PortalMath.translation(transform)
        let vol = DoorwayVolume()
        var count = 0
        for a in anchors where simd_distance(PortalMath.translation(a.transform), origin) < 4 {
            let vs = a.geometry.vertices
            let base = vs.buffer.contents()
            var i = 0
            while i < vs.count {
                let p = base.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
                let w = a.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                if vol.contains(PortalMath.toPortalSpace(SIMD3(w.x, w.y, w.z), portal: transform)) { count += 1 }
                i += 3                                   // sample every third vertex
            }
        }
        lastObstruction = (now, count)
        return count
    }

    private func evaluate(position: SIMD3<Float>, yaw: Float, plane: PlaneKind, extent: SIMD2<Float>, now: TimeInterval) -> PlacementIssue? {
        let cam = PortalMath.translation(arView.cameraTransform.matrix)
        let input = PlacementInput(hitPoint: position, cameraPosition: cam, planeKind: plane,
                                   lowestHorizontalPlaneY: lowestHorizontalPlaneY(), planeExtent: extent,
                                   obstructionPoints: plane == .wall ? nil : obstructionCount(for: PortalMath.transform(position: position, yaw: yaw), now: now),
                                   trackingNormal: quality == .normal)
        return rules.evaluate(input)
    }

    private func updateAiming(now: TimeInterval) {
        guard now - lastRaycast > 1.0 / 30 else { return }
        lastRaycast = now
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let hit = arView.raycast(from: centre, allowing: .existingPlaneGeometry, alignment: .vertical)
            .first { ($0.anchor as? ARPlaneAnchor)?.alignment == .vertical }
        guard let hit, let plane = hit.anchor as? ARPlaneAnchor else {
            candidate = nil
            currentIssue = .notAWall
            machine.handle(.placementValid(false))
            preview?.hide()
            setInstruction("Point at a wall and move the phone slowly", warning: false)
            return
        }
        let wallHit = PortalMath.translation(hit.worldTransform)
        let cam = PortalMath.translation(arView.cameraTransform.matrix)
        let n = plane.transform.columns.1
        guard let pose = PortalMath.wallPlacement(hit: wallHit, normal: SIMD3(n.x, n.y, n.z),
                                                  camera: cam, floorY: lowestHorizontalPlaneY(), dims: dims) else {
            candidate = nil
            currentIssue = .notAWall
            machine.handle(.placementValid(false))
            preview?.hide()
            return
        }
        let pos = PortalMath.translation(pose)
        let yaw = PortalMath.yaw(of: pose)
        let extent = SIMD2<Float>(plane.planeExtent.width, plane.planeExtent.height)
        candidate = (pos, yaw, .wall, extent)
        currentIssue = evaluate(position: pos, yaw: yaw, plane: .wall, extent: extent, now: now)
        machine.handle(.placementValid(currentIssue == nil))
        // Smooth only the aiming indicator. The confirmed opening never follows a raycast.
        let shown = displayPreviewPos.map { simd_mix($0, pos, SIMD3(repeating: 0.35)) } ?? pos
        displayPreviewPos = shown
        preview?.show(PortalMath.transform(position: shown, yaw: yaw), valid: currentIssue == nil)
        setInstruction(currentIssue?.message ?? "Tap to pin the opening to this wall", warning: currentIssue != nil)
    }

    private func updateAdjusting() {
        guard let p = pinned else { return }
        currentIssue = evaluate(position: p.position, yaw: p.yaw, plane: p.plane, extent: p.extent, now: CACurrentMediaTime())
        machine.handle(.placementValid(currentIssue == nil))
        preview?.show(PortalMath.transform(position: p.position, yaw: p.yaw), valid: currentIssue == nil)
        setInstruction(currentIssue?.message ?? "Drag to position the opening on the wall", warning: currentIssue != nil)
        let can = currentIssue == nil && warmupAnchor == nil
        if model?.canConfirm != can { model?.canConfirm = can }
    }

    private func updatePortal(dt: Float, now: TimeInterval, decision: TrackingDecision) {
        guard let rig, let ae = anchorEntity else { return }
        let portalWorld = ae.transformMatrix(relativeTo: nil)
        let physicalLocal = PortalMath.toPortalSpace(PortalMath.translation(arView.cameraTransform.matrix), portal: portalWorld)
        let camLocal = physicalLocal - (insideOffset ?? .zero)
        lastCameraLocal = camLocal
        let b = boundary.evaluate(cameraLocal: camLocal, dims: dims,
                                  allowCrossing: false)
        let t = Float(now - phaseStart)

        var look: PortalLook
        switch machine.phase {
        case .opening:
            look = OpeningTimeline.opening(at: t)
            if t >= OpeningTimeline.duration { machine.handle(.openingFinished); publishPhase() }
        case .closing:
            look = OpeningTimeline.closing(at: t)
            if t >= OpeningTimeline.closeDuration {
                removeDoorway()
                machine.handle(.closingFinished)
                pauseSession()
                publishPhase()
                return
            }
        default:
            look = .open
        }
        // tracking: pause the illusion, never move the doorway
        displayAperture = PortalMath.approach(displayAperture, decision.apertureVisible ? 1 : 0, rate: 12, dt: dt)
        displayFrame = PortalMath.approach(displayFrame, decision.frameVisible ? 1 : 0, rate: 7, dt: dt)
        look.apertureOpen *= displayAperture
        look.frameOpacity *= displayFrame
        look.veil = max(look.veil, 1 - b.clarity)
        currentLook = look
        rig.apply(look, worldVisible: b.worldVisible && look.apertureOpen > 0.001,
                  interiorVisible: b.worldVisible, insideWorld: b.insideWorld)
        // Room-side LiDAR geometry must not cut holes in the virtual alley
        // while the camera is inside. ARKit continues tracking the real room.
        occlusion.enabled = lidarSupported && lidarOcclusion && !b.insideWorld
        audio?.update(aperture: b.worldVisible ? look.apertureOpen * b.clarity : 0, frame: look.frameOpacity, muted: muted)

        if lidarOcclusion && !b.insideWorld, let anchors = arView.session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            occlusion.update(meshAnchors: anchors, portalWorld: portalWorld, now: now)
        }
        if decision.offerReplacement && model?.showReplaceOffer == false { model?.showReplaceOffer = true }
        let viewMessage = insideOffset != nil ? "Turn your phone to look around. Tap Back to room to return." : nil
        let msg = interrupted ? "Paused" : (decision.message ?? viewMessage ?? b.message)
        setInstruction(msg ?? "", warning: decision.message != nil || (!b.insideWorld && b.message != nil))
        if machine.phase == .open {
            diagnostics.soakTick(tracking: qualityText, corrections: corrections, maxCorrectionCm: Double(maxCorrection * 100), tier: tier.rawValue)
        }
    }

    // MARK: - gestures

    private func installGestures() {
        let tapG = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        let rot = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        let dev = UITapGestureRecognizer(target: self, action: #selector(onDevTap(_:)))
        dev.numberOfTouchesRequired = 3
        for g in [tapG, pan, rot, dev] as [UIGestureRecognizer] {
            g.delegate = self
            arView.addGestureRecognizer(g)
        }
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func onTap(_ g: UITapGestureRecognizer) { tap() }

    @objc private func onDevTap(_ g: UITapGestureRecognizer) { model?.devPanelVisible.toggle() }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .ended || g.state == .cancelled {
            placementPanOffset = nil
            return
        }
        guard machine.phase == .adjusting, var p = pinned else { return }
        let pt = g.location(in: arView)
        let normal = SIMD3<Float>(sin(p.yaw), 0, cos(p.yaw))
        guard let ray = arView.ray(through: pt),
              let hit = PortalMath.intersectPlane(origin: ray.origin, direction: ray.direction,
                                                   point: p.position, normal: normal) else { return }
        if g.state == .began || placementPanOffset == nil { placementPanOffset = hit - p.position }
        p.position = hit - (placementPanOffset ?? .zero)
        pinned = p
    }

    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        guard machine.phase == .adjusting, var p = pinned else { return }
        guard p.plane != .wall else { return } // keep the opening parallel to its wall
        p.yaw = PortalMath.wrapAngle(p.yaw - Float(g.rotation))
        g.rotation = 0
        pinned = p
    }

    // MARK: - UI publishing

    private func publishPhase() {
        guard let model else { return }
        if model.phase != machine.phase { model.phase = machine.phase }
        let can = machine.phase == .adjusting && currentIssue == nil
        if model.canConfirm != can { model.canConfirm = can }
        if machine.phase != .adjusting && machine.phase != .aiming { preview?.hide() }
        if machine.phase == .aiming { displayPreviewPos = nil }
    }

    private func setInstruction(_ s: String, warning: Bool) {
        guard let model else { return }
        if model.instruction != s { model.instruction = s }
        if model.instructionIsWarning != warning { model.instructionIsWarning = warning }
    }

    private var lastPublish: TimeInterval = 0
    private func publishDiagnostics(now: TimeInterval) {
        guard let model, model.devPanelVisible, now - lastPublish > 0.5 else { return }
        lastPublish = now
        let s = diagnostics.stats.summary()
        var d = DiagnosticsSnapshot()
        d.fps = s.fps; d.meanMs = s.meanMs; d.p95Ms = s.p95Ms; d.maxMs = s.maxMs; d.overBudgetPct = s.overBudget * 100
        d.memoryMB = Diagnostics.memoryFootprintMB()
        d.memoryStartMB = diagnostics.memoryAtLaunch
        d.thermal = Diagnostics.thermalString()
        d.tracking = qualityText + (lowLight ? " (low light)" : "")
        d.anchorCorrections = corrections
        d.maxCorrectionCm = Double(maxCorrection * 100)
        d.appWritesAfterLock = appWritesAfterLock
        d.cameraLocal = String(format: "x %.2f y %.2f z %.2f", lastCameraLocal.x, lastCameraLocal.y, lastCameraLocal.z)
        d.cameraLocal += boundary.insideWorld ? " (inside alley)" : " (room side)"
        d.tier = tier.rawValue
        if let a = assets { d.lights = tier.lightCount(a.manifest); d.shaderIssues = a.shaderFallbacks }
        d.triangles = rig?.triangleCount ?? 0
        d.lidar = lidarSupported ? (lidarOcclusion ? "occlusion on" : "occlusion off") : "not available"
        d.occluderTriangles = occlusion.triangleCount
        let up = Int(diagnostics.uptime)
        d.uptime = String(format: "%d:%02d", up / 60, up % 60)
        d.notes = model.notes
        if let e = audio?.loadError { d.notes.append("audio: \(e)") }
        model.diagnostics = d
    }
}




