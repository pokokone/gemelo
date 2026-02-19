import SwiftUI
import KeyboardShortcuts
import WebKit
import ServiceManagement

struct SettingsView: View {
    @Binding var coordinator: AppCoordinator
    @AppStorage(UserDefaultsKeys.pageZoom.rawValue) private var pageZoom: Double = Constants.defaultPageZoom
    @AppStorage(UserDefaultsKeys.hideWindowAtLaunch.rawValue) private var hideWindowAtLaunch: Bool = false
    @AppStorage(UserDefaultsKeys.hideDockIcon.rawValue) private var hideDockIcon: Bool = false
    @AppStorage(UserDefaultsKeys.focusInputShortcut.rawValue) private var focusInputShortcut: String = WebViewModel.defaultInputFocusShortcut
    @AppStorage(UserDefaultsKeys.newLocalChatShortcut.rawValue) private var newLocalChatShortcut: String = AppCoordinator.defaultNewLocalChatShortcut
    @AppStorage(UserDefaultsKeys.switchLocalChatShortcut.rawValue) private var switchLocalChatShortcut: String = AppCoordinator.defaultSwitchLocalChatShortcut
    @AppStorage(UserDefaultsKeys.closeLocalChatShortcut.rawValue) private var closeLocalChatShortcut: String = AppCoordinator.defaultCloseLocalChatShortcut

    @State private var showingResetAlert = false
    @State private var isClearing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch MenuBar at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch { launchAtLogin = !newValue }
                    }
                Toggle("Hide Desktop Window at Launch", isOn: $hideWindowAtLaunch)
                Toggle("Hide Dock Icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
            }
            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Toggle Chat Bar:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .bringToFront)
                }
                HStack {
                    Text("Focus Input:")
                    Spacer()
                    TextField("gi", text: $focusInputShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.center)
                        .onChange(of: focusInputShortcut) { _, newValue in
                            let normalized = WebViewModel.normalizeFocusInputShortcut(newValue)
                            if normalized != newValue {
                                focusInputShortcut = normalized
                                return
                            }
                            coordinator.webViewModel.updateFocusInputShortcut(normalized)
                        }
                }
                HStack {
                    Text("New Local Chat:")
                    Spacer()
                    TextField("cmd+t", text: $newLocalChatShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.center)
                        .onChange(of: newLocalChatShortcut) { oldValue, newValue in
                            let fallback = AppCoordinator.normalizeLocalShortcut(oldValue) ?? AppCoordinator.defaultNewLocalChatShortcut
                            let normalized = AppCoordinator.normalizeLocalShortcut(newValue) ?? fallback
                            if normalized != newValue {
                                newLocalChatShortcut = normalized
                                return
                            }
                            coordinator.reloadLocalShortcutSettings()
                        }
                }
                HStack {
                    Text("Switch Local Chat:")
                    Spacer()
                    TextField("ctrl+tab", text: $switchLocalChatShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.center)
                        .onChange(of: switchLocalChatShortcut) { oldValue, newValue in
                            let fallback = AppCoordinator.normalizeLocalShortcut(oldValue) ?? AppCoordinator.defaultSwitchLocalChatShortcut
                            let normalized = AppCoordinator.normalizeLocalShortcut(newValue) ?? fallback
                            if normalized != newValue {
                                switchLocalChatShortcut = normalized
                                return
                            }
                            coordinator.reloadLocalShortcutSettings()
                        }
                }
                HStack {
                    Text("Close Local Chat:")
                    Spacer()
                    TextField("cmd+w", text: $closeLocalChatShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.center)
                        .onChange(of: closeLocalChatShortcut) { oldValue, newValue in
                            let fallback = AppCoordinator.normalizeLocalShortcut(oldValue) ?? AppCoordinator.defaultCloseLocalChatShortcut
                            let normalized = AppCoordinator.normalizeLocalShortcut(newValue) ?? fallback
                            if normalized != newValue {
                                closeLocalChatShortcut = normalized
                                return
                            }
                            coordinator.reloadLocalShortcutSettings()
                        }
                }
                Text("Format: cmd+t, ctrl+tab, cmd+w")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Appearance") {
                HStack {
                    Text("Text Size: \(Int((pageZoom * 100).rounded()))%")
                    Spacer()
                    Stepper("",
                            value: $pageZoom,
                            in: Constants.minPageZoom...Constants.maxPageZoom,
                            step: Constants.pageZoomStep)
                        .onChange(of: pageZoom) { coordinator.webViewModel.wkWebView.pageZoom = $1 }
                        .labelsHidden()
                }
            }
            Section("Privacy") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reset Website Data")
                        Text("Clears cookies, cache, and login sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset", role: .destructive) { showingResetAlert = true }
                        .disabled(isClearing)
                        .overlay { if isClearing { ProgressView().scaleEffect(0.7) } }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset Website Data?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { clearWebsiteData() }
        } message: {
            Text("This will clear all cookies, cache, and login sessions. You will need to sign in again.")
        }
    }

    private func clearWebsiteData() {
        isClearing = true
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            dataStore.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async { isClearing = false }
            }
        }
    }
}

extension SettingsView {

    struct Constants {
        static let defaultPageZoom: Double = 1.0
        static let minPageZoom: Double = 0.6
        static let maxPageZoom: Double = 1.4
        static let pageZoomStep: Double = 0.01
    }

}
