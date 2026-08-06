import SwiftUI

struct ContentView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services

        ScrollView {
            VStack(spacing: 16) {
                preview
                serverCard
                sessionCard
                storageCard
                settingsCard(services: $services)
                logCard
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(session: services.capture.session)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if services.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("REC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(12)
            }

            if !services.permissionsGranted {
                VStack(spacing: 8) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.largeTitle)
                    Text("Camera access not granted")
                        .font(.callout.weight(.medium))
                    Text("Enable it in Settings › Camera API, then relaunch.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    // MARK: - Cards

    private var serverCard: some View {
        Card(title: "Server", accent: services.serverIsHealthy ? .green : .orange) {
            LabeledRow(label: "State", value: services.serverStateText)
            LabeledRow(label: "Access", value: services.accessMode == .usbOnly ? "USB only (loopback)" : "Any interface")
            LabeledRow(label: "Auth", value: services.authToken.isEmpty ? "None" : "Bearer token set")
            LabeledRow(label: "Clients", value: "\(services.streamClients) stream · \(services.eventClients) events")

            Divider().overlay(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 4) {
                Text("On the Linux host")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(services.iproxyCommand)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                Text("curl http://localhost:\(services.port)/status")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }
        }
    }

    private var sessionCard: some View {
        Card(title: "Capture", accent: .blue) {
            LabeledRow(label: "Session", value: services.sessionSummary)
            LabeledRow(label: "Recording", value: services.recordingSummary)
        }
    }

    private var storageCard: some View {
        Card(title: "Storage", accent: .purple) {
            Text(services.storageSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard(services bindable: Bindable<AppServices>) -> some View {
        Card(title: "Settings", accent: .gray) {
            Picker("Access", selection: bindable.accessMode) {
                Text("USB only").tag(AccessMode.usbOnly)
                Text("Any interface").tag(AccessMode.network)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Port")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("8080", value: bindable.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(width: 90)
            }

            HStack {
                Text("Token")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("optional", text: bindable.authToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: 180)
            }

            if services.accessMode == .network {
                Text("Any device on this network can reach the API. Set a token.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var logCard: some View {
        Card(title: "Log", accent: .gray) {
            if services.logLines.isEmpty {
                Text("No events yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(services.logLines.suffix(12).reversed()) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                            Text(line.message)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppServices())
}
