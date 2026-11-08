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
                Text("Place a doorway in your room and look through it into a rainy night alley.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Reach your phone through the opening to look around the alley. Pull it back through the doorway to return.")
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
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }
}

private struct BottomControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.phase {
        case .scanning, .aiming:
            HStack {
                RoundButton(system: "xmark", label: "Close", action: model.close)
                Spacer()
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
                .tint(Color(red: 0.25, green: 0.78, blue: 0.9))
                .disabled(!model.canConfirm)
            }
        case .opening, .open, .closing:
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    RoundButton(system: "arrow.triangle.2.circlepath", label: "Reposition", action: model.reposition)
                    RoundButton(system: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                label: model.muted ? "Unmute" : "Mute", action: model.toggleMute)
                    RoundButton(system: "xmark", label: "Close", action: model.close)
                }
            }
        case .idle:
            EmptyView()
        }
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

