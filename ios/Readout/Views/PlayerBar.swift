import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var reader: Reader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reader.status).font(.footnote).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            if reader.active && !reader.now.isEmpty {
                Text(reader.now)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                small("arrow.counterclockwise", label: "Replay line", disabled: !reader.active) { reader.back() }
                Button(action: model.playPause) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(Theme.amberInk)
                        .background(Theme.amber, in: Circle())
                }
                .accessibilityLabel(playing ? "Pause" : reader.phase == .paused ? "Resume" : "Play answer")
                small("forward.end.fill", label: "Skip to next line", disabled: !reader.active) { reader.next() }
                small("stop.fill", label: "Stop reading", disabled: !reader.active) { reader.stop() }
                Spacer(minLength: 0)
                Button(action: model.cycleSpeed) {
                    Text(AppModel.rateLabel(settings.rate))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 11).frame(height: 34)
                        .background(Theme.panel2, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                        .foregroundStyle(Theme.text)
                }
                .accessibilityLabel("Reading speed")
                small("doc.on.doc", label: "Copy answer", disabled: false) { model.copy() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var playing: Bool { reader.active && reader.phase != .paused }

    private func small(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 42)
                .foregroundStyle(Theme.text)
                .background(Theme.panel2, in: Circle())
                .overlay(Circle().stroke(Theme.line))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}
