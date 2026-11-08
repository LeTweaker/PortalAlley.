import PortalCore
import RealityKit
import SwiftUI
import UIKit

struct ARPortalView: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> ARView { model.makeController().arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            ARPortalView(model: model)
                .ignoresSafeArea()

            if model.phase == .idle {
                StartCard(model: model)
            } else {
                VStack(spacing: 0) {
                    InstructionPill(text: model.instruction, warning: model.instructionIsWarning)
                        .padding(.top, 12)
                        .onLongPressGesture(minimumDuration: 1.5) { model.devPanelVisible.toggle() }
                    if model.devPanelVisible {
                        DeveloperPanel(model: model)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                    if let c = model.confirmation {
                        ConfirmationBanner(text: c).padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.showReplaceOffer { ReplaceCard(model: model).padding(.bottom, 16) }
                    BottomControls(model: model)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 16)
            }

            if let msg = model.fatalMessage {
                FatalCard(message: msg)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .animation(.easeOut(duration: 0.2), value: model.devPanelVisible)
        .animation(.easeOut(duration: 0.25), value: model.confirmation)
        .statusBarHidden(true)
    }
}

private struct InstructionPill: View {
    let text: String
    let warning: Bool
    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                .overlay(Capsule().stroke(warning ? Color.orange.opacity(0.7) : Color.white.opacity(0.15), lineWidth: 1))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            Color.clear.frame(height: 38)
        }
    }
}

private struct StartCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(spacing: 10) {
                Text("Portal")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Version 1.4.0")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Open a window into a real, photographed alley in 3D - or onto genuine Tokyo rain footage.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Point at a wall, the floor or the ceiling and tap CREATE PORTAL. Nothing found? It places a standing doorway in front of you.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 4)
                Button(action: model.start) {
                    Text(model.assetsReady ? "Start" : "Loading…")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.25, green: 0.78, blue: 0.9))
                .disabled(!model.assetsReady)
                .padding(.top, 8)
                VStack(spacing: 3) {
                    Text("3D scene: \u{201C}Woolwich Alley\u{201D} by artfletch · CC BY 4.0")
                    Text("Footage: \u{201C}Heavy rain in early spring in Tokyo\u{201D} by Fumikas Sagisavas · CC BY 4.0")
                    Link("Illustrated alley textures & props: Poly Haven · CC0", destination: URL(string: "https://polyhaven.com/license")!)
                }
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }
}

private let portalTint = Color(red: 0.25, green: 0.78, blue: 0.9)

private struct BottomControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.phase {
        case .scanning, .aiming:
            if model.easyMode {
                CreatePanel(model: model)
            } else {
                HStack {
                    RoundButton(system: "xmark", label: "Close", action: model.close)
                    Spacer()
                    Button("Restart scan", action: model.restartScan)
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.12, green: 0.4, blue: 0.46))
                }
            }
        case .adjusting:
            HStack(spacing: 12) {
                Button(action: model.back) {
                    Text("Back").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button(action: model.confirm) {
                    Text("Open portal").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(portalTint)
                .disabled(!model.canConfirm)
            }
        case .opening, .open, .closing:
            PlacedControls(model: model)
        case .idle:
            EmptyView()
        }
    }
}

/// Spatial 3D (captured scene) or Cinematic (genuine flat footage), plus the
/// credit the CC BY licences require for whatever is showing.
private struct ViewingPicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 4) {
            if model.cinematicAvailable {
                Picker("View", selection: Binding(get: { model.viewingMode }, set: { model.setViewingMode($0) })) {
                    ForEach(ViewingMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }
            if !model.destinationCredit.isEmpty {
                Text(model.destinationCredit)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// After placement the UI stays small: Reposition / Adjust / Close Portal.
/// Adjust reveals Resize (and Rotate for openings not standing on the floor).
private struct PlacedControls: View {
    @ObservedObject var model: AppModel
    @State private var adjusting = false
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom) {
                if model.portalOffscreen && !model.insideView && model.phase == .open {
                    FindPortalButton(model: model)
                }
                Spacer()
                RoundButton(system: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            label: model.muted ? "Unmute" : "Mute", action: model.toggleMute)
            }
            ViewingPicker(model: model)
            if adjusting && model.phase == .open {
                AdjustRow(model: model).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.portalKind == "wall" && model.destinationKind != "video" {
                Button(action: model.toggleInsideView) {
                    Label(model.insideView ? "Back to room" : "Look inside",
                          systemImage: model.insideView ? "arrow.uturn.backward" : "viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.4, blue: 0.46))
                .disabled(model.phase != .open)
            }
            HStack(spacing: 8) {
                PillButton(title: "Reposition", system: "arrow.up.and.down.and.arrow.left.and.right", action: model.movePortal)
                    .disabled(model.phase == .closing)
                PillButton(title: adjusting ? "Done" : "Adjust", system: adjusting ? "checkmark" : "slider.horizontal.3") {
                    withAnimation(.easeOut(duration: 0.2)) { adjusting.toggle() }
                }
                .disabled(model.phase != .open || model.insideView)
                PillButton(title: "Close Portal", system: "xmark", action: model.close)
                    .disabled(model.phase == .closing)
            }
            Button(action: model.restartScan) {
                Text("RESTART SCAN").font(.system(size: 12, weight: .semibold)).padding(.vertical, 2)
            }
            .buttonStyle(.borderless)
            .tint(.white.opacity(0.8))
        }
        .onChange(of: model.phase) { _, phase in if phase != .open { adjusting = false } }
    }
}

/// Resize (aperture only - the alley keeps real-world scale) and Rotate.
private struct AdjustRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { model.resizePortal(grow: false) } label: { Image(systemName: "minus").frame(width: 34, height: 34) }
                    .disabled(!model.canShrink).accessibilityLabel("Smaller")
                Text(model.portalScaleText).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(minWidth: 44)
                Button { model.resizePortal(grow: true) } label: { Image(systemName: "plus").frame(width: 34, height: 34) }
                    .disabled(!model.canGrow).accessibilityLabel("Bigger")
            }
            .padding(.horizontal, 8)
            .background(.ultraThinMaterial, in: Capsule())
            if model.canRotate {
                HStack(spacing: 4) {
                    Button { model.rotatePortal(clockwise: false) } label: { Image(systemName: "rotate.left").frame(width: 34, height: 34) }
                        .accessibilityLabel("Rotate left")
                    Button { model.rotatePortal(clockwise: true) } label: { Image(systemName: "rotate.right").frame(width: 34, height: 34) }
                        .accessibilityLabel("Rotate right")
                }
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .font(.system(size: 16, weight: .semibold))
    }
}

private struct PillButton: View {
    let title: String
    let system: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }
}

/// Easy Mode: the one big action, with what will happen and why.
private struct CreatePanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            if model.phase == .aiming, !model.placementMethod.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: model.placementMethod.hasPrefix("No surface") ? "figure.stand" :
                            (model.placementMethod.hasPrefix("Floor") ? "arrow.down.to.line" :
                                (model.placementMethod.hasPrefix("Ceiling") ? "arrow.up.to.line" : "rectangle.portrait.and.arrow.forward")))
                    Text(model.placementMethod)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                if let hint = model.placementHint {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                }
            }
            ViewingPicker(model: model)
            Button(action: model.createPortal) {
                HStack(spacing: 10) {
                    Image(systemName: "door.left.hand.open")
                    Text(model.phase == .scanning ? "STARTING CAMERA…" : "CREATE PORTAL")
                }
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(portalTint)
            .disabled(!model.canCreate)
            .accessibilityHint("Opens the portal where the glowing outline is")
            HStack {
                RoundButton(system: "xmark", label: "Close", action: model.close)
                Spacer()
                Button(action: model.restartScan) {
                    Label("RESTART SCAN", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }
}

private struct FindPortalButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button(action: model.findPortal) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.radians(model.findArrowAngle))
                    .animation(.easeOut(duration: 0.15), value: model.findArrowAngle)
                Text("Find Portal").fontWeight(.semibold)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(portalTint)
        .accessibilityLabel("Find Portal")
    }
}

private struct ConfirmationBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.6))
            Text(text).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct RoundButton: View {
    let system: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

private struct ReplaceCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Text("The doorway's position couldn't be restored yet.")
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Keep waiting", action: model.keepWaiting).buttonStyle(.bordered).tint(.white)
                Button("Place again", action: model.placeAgain).buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.25, green: 0.78, blue: 0.9))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FatalCard: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            if message.contains("Settings") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }
}



