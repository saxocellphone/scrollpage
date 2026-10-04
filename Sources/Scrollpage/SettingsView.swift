import SwiftUI

/// The menu bar popover: an on/off switch and three settings, nothing else.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var openPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scrollpage").font(.headline)
                    Text(model.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("Scrollpage", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if model.needsPermissions {
                PermissionsBanner(model: model)
            }

            Divider()

            SpeedSlider(title: "Tracking speed", value: $model.trackingSpeed)
            SpeedSlider(title: "Scrolling speed", value: $model.scrollingSpeed)
            Toggle("Natural scrolling", isOn: $model.naturalScrolling)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                MenuRowButton(title: "Camera Preview & Tutorial…", action: openPreview)
                MenuRowButton(title: "Quit Scrollpage") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

private struct SpeedSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            HStack(spacing: 8) {
                Text("Slow").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $value, in: 0...1)
                    .controlSize(.small)
                Text("Fast").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MenuRowButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PermissionsBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.cameraStatus != .authorized {
                PermissionRow(title: "Camera", detail: "To see your hand", granted: false,
                              action: model.requestCamera)
            }
            if !model.accessibilityTrusted {
                PermissionRow(title: "Accessibility", detail: "To move the pointer, click and scroll",
                              granted: false, action: model.requestAccessibility)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…", action: action).controlSize(.small)
            }
        }
    }
}
