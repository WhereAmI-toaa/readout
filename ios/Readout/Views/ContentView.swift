import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var reader: Reader
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var pinchStart: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let safe = geo.safeAreaInsets
            let bw = min(size.width * 0.78, 420)
            let bracket = CGRect(x: (size.width - bw) / 2, y: size.height * 0.31 - bw * 0.375, width: bw, height: bw * 0.75)
            ZStack(alignment: .top) {
                Theme.ink
                finder
                    .gesture(MagnificationGesture()
                        .onChanged { v in model.setZoom(pinchStart * v) }
                        .onEnded { _ in pinchStart = model.zoom })
                Brackets(locked: reader.active && settings.waitForVoice && settings.auto, thinking: model.busy)
                    .frame(width: bracket.width, height: bracket.height)
                    .position(x: bracket.midX, y: bracket.midY)
                    .allowsHitTesting(false)
                if model.cameraState == .ready || model.demo {
                    Text(model.hintText)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.scrim, in: Capsule())
                        .foregroundStyle(Theme.text)
                        .position(x: size.width / 2, y: bracket.minY - 22)
                        .allowsHitTesting(false)
                }
                VStack(spacing: 0) {
                    topBar.padding(.top, safe.top + 6)
                    Spacer(minLength: 0)
                    bottom(height: size.height).padding(.bottom, max(safe.bottom, 10) + 4)
                }
                .padding(.horizontal, 16)
            }
            .ignoresSafeArea()
            .onAppear {
                model.viewSize = size
                model.bracketRect = bracket
            }
            .onChange(of: size) { _, s in
                let w = min(s.width * 0.78, 420)
                model.viewSize = s
                model.bracketRect = CGRect(x: (s.width - w) / 2, y: s.height * 0.31 - w * 0.375, width: w, height: w * 0.75)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(false)
        .onAppear { model.startCamera() }
        .onChange(of: scenePhase) { _, p in model.scenePhaseChanged(p) }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    model.ask(.photo, image: img)
                } else {
                    model.show("That photo couldn't be opened. Try another one.", warn: true)
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model).environmentObject(settings).environmentObject(reader)
        }
        .sheet(isPresented: $model.showSaved) {
            SavedView().environmentObject(model)
        }
    }

    // MARK: Viewfinder

    @ViewBuilder private var finder: some View {
        if let still = model.still {
            Image(uiImage: still).resizable().scaledToFill().opacity(0.55).clipped()
        } else if model.cameraState == .ready {
            CameraPreview(session: model.camera.session) { p in model.camera.focus(at: p) }
        } else {
            VStack(spacing: 10) {
                Text(placeholderTitle).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                Text(placeholderBody).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if model.cameraState == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 260)
            .background(RadialGradient(colors: [Theme.panel2, Theme.ink], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 10, endRadius: 520))
        }
    }

    private var placeholderTitle: String {
        switch model.cameraState {
        case .starting: return "Starting camera"
        case .denied: return "Camera is off"
        default: return "Snap a question"
        }
    }

    private var placeholderBody: String {
        switch model.cameraState {
        case .starting: return "Allow camera access when your phone asks."
        case .denied: return "Readout needs the camera. Turn it on in Settings, or pick a photo instead."
        default: return "Pick a photo with the button at the bottom left. Readout reads the question, then each answer, out loud."
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder").foregroundStyle(Theme.amber).font(.system(size: 17, weight: .bold))
                Text("READOUT").font(.system(size: 19, weight: .heavy).width(.condensed)).tracking(0.4)
            }
            Spacer()
            if model.cameraState == .ready {
                Button(action: model.toggleAuto) {
                    Text("AUTO").font(.system(size: 12, weight: .semibold)).tracking(1)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(settings.auto ? Theme.amberInk : Theme.muted)
                        .background(settings.auto ? Theme.amber : Theme.scrim, in: Capsule())
                        .overlay(Capsule().stroke(settings.auto ? Theme.amber : Theme.line))
                }
                .accessibilityLabel(settings.auto ? "Auto answer on" : "Auto answer off")
                if model.camera.hasTorch {
                    roundButton(model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", tint: model.torchOn ? Theme.amber : Theme.text, label: "Flashlight", action: model.toggleTorch)
                }
            }
            roundButton(settings.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill", tint: settings.voiceOn ? Theme.text : Theme.danger,
                        label: settings.voiceOn ? "Mute" : "Unmute", action: model.toggleMute)
            roundButton("slider.horizontal.3", tint: Theme.text, label: "Settings") { model.showSettings = true }
        }
        .foregroundStyle(Theme.text)
    }

    private func roundButton(_ symbol: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(tint)
                .background(Theme.scrim, in: Circle())
                .overlay(Circle().stroke(Theme.line))
        }
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private func bottom(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            if let t = model.toast {
                Text(t).font(.subheadline).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(model.toastWarn ? Theme.danger : Theme.text)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.toastWarn ? Theme.danger.opacity(0.55) : Theme.line))
                    .transition(.opacity)
            }
            sheet.frame(height: height * (model.expanded ? 0.7 : 0.43))
            dock
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.25), value: model.expanded)
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            Button { model.expanded.toggle() } label: {
                Capsule().fill(Theme.line).frame(width: 34, height: 4).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .accessibilityLabel(model.expanded ? "Shrink answer" : "Expand answer")
            HStack(spacing: 10) {
                Text(model.tag.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(tagForeground)
                    .background(tagBackground, in: RoundedRectangle(cornerRadius: 6))
                Text(model.meta).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            AnswerCard(entry: model.current, final: model.cardFinal, working: model.working, quiet: model.quiet,
                       highlight: reader.active ? reader.nowPart : nil)
            if model.playerReady || reader.active {
                PlayerBar()
            }
        }
        .background(Theme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var tagForeground: Color {
        switch model.tagKind {
        case .answer: return Theme.amberInk
        case .working: return Theme.amber
        case .error: return Theme.danger
        case .plain: return Theme.muted
        }
    }

    private var tagBackground: Color { model.tagKind == .answer ? Theme.amber : Theme.panel2 }

    private var dock: some View {
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .semibold))
                    .frame(width: 50, height: 50)
                    .background(Theme.scrim, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Choose a photo")
            .frame(maxWidth: .infinity)
            Shutter(progress: model.ring, busy: model.busy) {
                if model.cameraState == .ready || model.busy { model.shutterTapped() }
                else { model.show("The camera isn't on. Use the photo button to pick a picture.", warn: true) }
            }
            Button { model.showSaved = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 20, weight: .semibold))
                    .frame(width: 50, height: 50)
                    .background(Theme.scrim, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Saved answers")
            .frame(maxWidth: .infinity)
        }
    }
}

struct Brackets: View {
    var locked: Bool
    var thinking: Bool
    @State private var pulse = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, a: CGFloat = 26
            Path { p in
                p.move(to: CGPoint(x: 0, y: a)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: a, y: 0))
                p.move(to: CGPoint(x: w - a, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: a))
                p.move(to: CGPoint(x: 0, y: h - a)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: a, y: h))
                p.move(to: CGPoint(x: w - a, y: h)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - a))
            }
            .stroke(locked ? Theme.muted : Theme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .opacity(thinking && pulse ? 0.35 : 1)
        .scaleEffect(thinking && pulse ? 0.97 : 1)
        .onChange(of: thinking) { _, t in
            if t { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true } }
            else { withAnimation(.default) { pulse = false } }
        }
    }
}

struct Shutter: View {
    var progress: Double
    var busy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(busy ? Theme.amber : Theme.text, lineWidth: 4).opacity(0.9)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
                if busy {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.amber).frame(width: 30, height: 30)
                } else {
                    Circle().fill(Theme.text).frame(width: 60, height: 60)
                        .overlay(Image(systemName: "text.viewfinder").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink))
                }
            }
            .frame(width: 78, height: 78)
        }
        .accessibilityLabel(busy ? "Stop" : "Answer what's in view")
    }
}
