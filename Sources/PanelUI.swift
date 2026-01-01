import SwiftUI

@MainActor
final class PanelModel: ObservableObject {
    struct Snapshot {
        var isActive: Bool
        var durationSeconds: Int
        var keepDisplayAwake: Bool
        var launchAtLoginEnabled: Bool
        var launchAtLoginOn: Bool
        var remainingLabel: String?
        var updateTitle: String?
        var hasUpdateURL: Bool
    }

    var getSnapshot: (() -> Snapshot)?
    var setActive: ((Bool) -> Void)?
    var setDuration: ((Int) -> Void)?
    var setKeepDisplayAwake: ((Bool) -> Void)?
    var toggleLaunchAtLogin: (() -> Void)?
    var openUpdate: (() -> Void)?
    var quit: (() -> Void)?

    @Published var isActive: Bool = false
    @Published var durationSeconds: Int = 0
    @Published var keepDisplayAwake: Bool = false
    @Published var launchAtLoginEnabled: Bool = false
    @Published var launchAtLoginOn: Bool = false
    @Published var remainingLabel: String? = nil
    @Published var updateTitle: String? = nil
    @Published var hasUpdateURL: Bool = false

    func refresh() {
        guard let snap = getSnapshot?() else { return }
        isActive = snap.isActive
        durationSeconds = snap.durationSeconds
        keepDisplayAwake = snap.keepDisplayAwake
        launchAtLoginEnabled = snap.launchAtLoginEnabled
        launchAtLoginOn = snap.launchAtLoginOn
        remainingLabel = snap.remainingLabel
        updateTitle = snap.updateTitle
        hasUpdateURL = snap.hasUpdateURL
    }
}

struct PanelContentView: View {
    @ObservedObject var model: PanelModel

    private let durations: [(label: String, seconds: Int)] = [
        ("∞", 0),
        ("15m", 15 * 60),
        ("30m", 30 * 60),
        ("1h", 60 * 60),
        ("2h", 2 * 60 * 60)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(model.isActive ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .frame(width: 8, height: 8)
                    .scaleEffect(model.isActive ? 1.0 : 0.85)
                    .opacity(model.isActive ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.18), value: model.isActive)

                Label("Barista", systemImage: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: model.isActive)

                Spacer()

                if model.isActive, let remaining = model.remainingLabel {
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("", isOn: Binding(
                    get: { model.isActive },
                    set: { newValue in model.setActive?(newValue) }
                ))
                .labelsHidden()
                .toggleStyle(PillToggleStyle(onColor: .green))
            }

            Picker("Duration", selection: Binding(
                get: { model.durationSeconds },
                set: { model.setDuration?($0) }
            )) {
                ForEach(durations, id: \.seconds) { item in
                    Text(item.label).tag(item.seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Toggle("Keep Display Awake", isOn: Binding(
                get: { model.keepDisplayAwake },
                set: { model.setKeepDisplayAwake?($0) }
            ))

            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLoginOn },
                set: { _ in model.toggleLaunchAtLogin?() }
            ))
            .disabled(!model.launchAtLoginEnabled)

            if let updateTitle = model.updateTitle, model.hasUpdateURL {
                Button(updateTitle) { model.openUpdate?() }
                    .buttonStyle(.bordered)
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit") { model.quit?() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .tint(model.isActive ? .green : .accentColor)
    }
}

struct PillToggleStyle: ToggleStyle {
    var onColor: Color = .green

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(onColor.gradient) : AnyShapeStyle(.quaternary))

                Circle()
                    .fill(.background)
                    .shadow(radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 42, height: 24)
            .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Keep Awake"))
        .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
    }
}
