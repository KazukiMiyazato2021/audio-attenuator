import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: MixerController
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            globalControls
            Divider()
            appList
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
            Text("Attenuator").font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { controller.muteAll },
                set: { controller.muteAll = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Mute everything")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var globalControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VolumeRow(
                label: "Master",
                systemImage: "speaker.wave.3.fill",
                value: Binding(
                    get: { controller.masterVolume },
                    set: { controller.masterVolume = $0 }
                )
            )
            VolumeRow(
                label: "Other apps",
                systemImage: "square.stack.3d.up",
                value: Binding(
                    get: { controller.fallbackVolume },
                    set: { controller.fallbackVolume = $0 }
                )
            )

            HStack {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { controller.selectedOutputUID ?? "" },
                    set: { controller.selectedOutputUID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(controller.outputDevices.filter { !$0.isVirtual }, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var appList: some View {
        Group {
            if controller.apps.isEmpty {
                Text("No audio apps detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.apps) { app in
                            AppVolumeRow(
                                app: app,
                                onLiveChange: { controller.setVolume($0, for: app.bundleID, live: true) },
                                onCommit: { controller.setVolume($0, for: app.bundleID) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(controller.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Reset") { controller.resetAll() }
                .buttonStyle(.link)
                .font(.caption)
            Button("Quit") { onQuit() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A labelled 0-150% slider.
private struct VolumeRow: View {
    let label: String
    let systemImage: String
    @Binding var value: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            Slider(value: $value, in: 0...1.5)
            Text("\(Int(value * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AppVolumeRow: View {
    let app: AppRow
    let onLiveChange: (Float) -> Void
    let onCommit: (Float) -> Void

    @State private var localValue: Float = 1.0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                            .help("Playing now")
                    }
                }
                // Apply while dragging so the volume follows the slider, and
                // commit once on release for the expensive bookkeeping.
                Slider(value: $localValue, in: 0...1.5) { editing in
                    isDragging = editing
                    if !editing { onCommit(localValue) }
                }
                .onChange(of: localValue) { _, newValue in
                    if isDragging { onLiveChange(newValue) }
                }
            }

            Text("\(Int(localValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(app.isTapped ? .primary : .secondary)
        }
        .onAppear { localValue = app.volume }
        // Keep in step with external changes (reset, another window) without
        // fighting the user mid-drag.
        .onChange(of: app.volume) { _, newValue in
            // Never fight the user mid-drag.
            guard !isDragging else { return }
            if abs(newValue - localValue) > 0.001 { localValue = newValue }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}
