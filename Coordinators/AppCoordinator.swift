//
//  AppCoordinator.swift
//  Gemelo
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@Observable
class AppCoordinator {
    private var chatBar: ChatBarPanel?
    private var chatSessions: [ChatSession]
    private var currentSessionIndex: Int = 0
    var webViewModel: WebViewModel

    var openWindowAction: ((String) -> Void)?
    private var localKeyMonitor: Any?
    private weak var systemCloseMenuItem: NSMenuItem?
    private var systemCloseMenuOriginalKeyEquivalent: String?
    private var systemCloseMenuOriginalModifierMask: NSEvent.ModifierFlags?

    private var newChatShortcut: LocalShortcut
    private var switchChatShortcut: LocalShortcut
    private var closeChatShortcut: LocalShortcut
    private var prewarmedSessions: [ChatSession] = []
    private var prewarmedSessionsInFlight = 0
    private var pendingNewChatRequestQueue: [UUID] = []
    private var pendingNewChatFallbackWorkItems: [UUID: DispatchWorkItem] = [:]

    var canGoBack: Bool { webViewModel.canGoBack }
    var canGoForward: Bool { webViewModel.canGoForward }
    var currentChatNumber: Int { currentSessionIndex + 1 }
    var totalChatCount: Int { chatSessions.count }

    var newChatShortcutHint: String { newChatShortcut.normalized }
    var switchChatShortcutHint: String { switchChatShortcut.normalized }
    var closeChatShortcutHint: String { closeChatShortcut.normalized }

    static let defaultNewLocalChatShortcut = "cmd+t"
    static let defaultSwitchLocalChatShortcut = "ctrl+tab"
    static let defaultCloseLocalChatShortcut = "cmd+w"

    init() {
        let initialSession = ChatSession(id: UUID(), webViewModel: WebViewModel())
        self.chatSessions = [initialSession]
        self.webViewModel = initialSession.webViewModel

        self.newChatShortcut = Self.parseShortcut(Self.defaultNewLocalChatShortcut)!
        self.switchChatShortcut = Self.parseShortcut(Self.defaultSwitchLocalChatShortcut)!
        self.closeChatShortcut = Self.parseShortcut(Self.defaultCloseLocalChatShortcut)!
        loadLocalShortcutSettings()
        initialSession.webViewModel.ensureThinkingMode()
        preparePrewarmedSessionsIfNeeded()

        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }
    }

    // MARK: - Navigation

    func goBack() { webViewModel.goBack() }
    func goForward() { webViewModel.goForward() }
    func goHome() { webViewModel.loadHome() }
    func reload() { webViewModel.reload() }

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Local Chats

    func createNewChat() {
        if let preparedSession = takePrewarmedSession() {
            #if DEBUG
            print("[AppCoordinator] Using prewarmed session. Remaining prewarmed: \(prewarmedSessions.count)")
            #endif
            appendAndActivateSession(preparedSession)
            preparePrewarmedSessionsIfNeeded()
            return
        }

        let requestID = enqueuePendingNewChatRequest()
        #if DEBUG
        print("[AppCoordinator] No prewarmed session available. Queued request count: \(pendingNewChatRequestQueue.count)")
        #endif
        preparePrewarmedSessionsIfNeeded(urgent: true)
        scheduleFallbackLiveCreation(for: requestID)
    }

    func switchToNextChat() {
        guard chatSessions.count > 1 else { return }
        let nextIndex = (currentSessionIndex + 1) % chatSessions.count
        activateSession(at: nextIndex)
    }

    func closeCurrentChat() {
        guard chatSessions.count > 1 else {
            if let bar = chatBar, bar.isVisible {
                hideChatBar()
            } else {
                closeMainWindow()
            }
            return
        }

        chatSessions.remove(at: currentSessionIndex)
        let nextIndex = min(currentSessionIndex, chatSessions.count - 1)
        activateSession(at: nextIndex)
    }

    func installLocalShortcutMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        updateSystemCloseWindowCommandOverride()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let targetWindow = event.window ?? NSApp.keyWindow

            if self.shortcut(self.closeChatShortcut, matches: event) {
                if self.isChatContext(window: targetWindow) {
                    self.closeCurrentChat()
                    return nil
                }

                if self.closeChatShortcut.normalized == Constants.systemCloseShortcut {
                    targetWindow?.performClose(nil)
                    return nil
                }
            }

            guard self.isChatContext(window: targetWindow) else { return event }

            if self.shortcut(self.newChatShortcut, matches: event) {
                self.createNewChat()
                return nil
            }

            if self.shortcut(self.switchChatShortcut, matches: event) {
                self.switchToNextChat()
                return nil
            }

            return event
        }
    }

    func reloadLocalShortcutSettings() {
        loadLocalShortcutSettings()
    }

    static func normalizeLocalShortcut(_ raw: String) -> String? {
        parseShortcut(raw)?.normalized
    }

    func isShortcutInChatContext() -> Bool {
        isChatContext(window: NSApp.keyWindow)
    }

    // MARK: - Chat Bar

    func showChatBar() {
        // Hide main window when showing chat bar
        closeMainWindow()

        if let existing = chatBar {
            existing.orderOut(nil)
            chatBar = nil
        }

        let contentView = ChatBarView(
            webView: webViewModel.wkWebView,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(contentView: hostingView)

        // Position at bottom center of the screen where mouse is located
        if let screen = NSScreen.screenAtMouseLocation() {
            let origin = screen.bottomCenterPoint(for: bar.frame.size, dockOffset: Constants.dockOffset)
            bar.setFrameOrigin(origin)
        }

        bar.orderFront(nil)
        bar.makeKeyAndOrderFront(nil)
        chatBar = bar
    }

    func hideChatBar() {
        chatBar?.orderOut(nil)
        chatBar = nil
    }

    func closeMainWindow() {
        guard let window = findMainWindow(), !(window is NSPanel) else { return }
        window.orderOut(nil)
    }

    func toggleChatBar() {
        if let bar = chatBar, bar.isVisible {
            hideChatBar()
        } else {
            showChatBar()
        }
    }

    func expandToMainWindow() {
        // Capture the screen where the chat bar is located before hiding it
        let targetScreen = chatBar.flatMap { bar -> NSScreen? in
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            return NSScreen.screen(containing: center)
        } ?? NSScreen.main

        hideChatBar()
        openMainWindow(on: targetScreen)
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()

        if let window = mainWindow {
            if window.identifier?.rawValue != Constants.mainWindowIdentifier {
                window.identifier = NSUserInterfaceItemIdentifier(Constants.mainWindowIdentifier)
            }
            // Window exists - show it (works for suppressed windows too)
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
            // Position newly created window with retry mechanism
            if let screen = targetScreen {
                centerNewlyCreatedWindow(on: screen)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        focusCurrentPromptInput()
    }

    /// Finds the main window by identifier or hosted WebView
    private func findMainWindow() -> NSWindow? {
        if let byIdentifier = NSApp.windows.first(where: { $0.identifier?.rawValue == Constants.mainWindowIdentifier }) {
            return byIdentifier
        }

        if let byWebView = NSApp.windows.first(where: { !($0 is NSPanel) && windowContainsGemeloWebView($0) }) {
            return byWebView
        }

        return NSApp.windows.first { !($0 is NSPanel) && $0.title == Constants.mainWindowTitle }
    }

    /// Centers a window on the specified screen
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let origin = screen.centerPoint(for: window.frame.size)
        window.setFrameOrigin(origin)
    }

    /// Centers a newly created window on the target screen with retry mechanism
    private func centerNewlyCreatedWindow(on screen: NSScreen, attempt: Int = 1) {
        let maxAttempts = 5
        let retryDelay = 0.05 // 50ms between attempts

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self = self else { return }

            if let window = self.findMainWindow() {
                if window.identifier?.rawValue != Constants.mainWindowIdentifier {
                    window.identifier = NSUserInterfaceItemIdentifier(Constants.mainWindowIdentifier)
                }
                self.centerWindow(window, on: screen)
            } else if attempt < maxAttempts {
                // Window not found yet, retry
                self.centerNewlyCreatedWindow(on: screen, attempt: attempt + 1)
            }
        }
    }

    private func activateSession(at index: Int) {
        guard chatSessions.indices.contains(index) else { return }
        currentSessionIndex = index
        webViewModel = chatSessions[index].webViewModel
        refreshChatBarIfVisible()
        focusCurrentPromptInput()
    }

    private func focusCurrentPromptInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.webViewModel.focusPromptInput()
        }
    }

    private func preparePrewarmedSessionsIfNeeded(urgent: Bool = false) {
        let targetCount = max(
            Constants.prewarmedSessionTarget,
            pendingNewChatRequestQueue.count + Constants.prewarmedSessionBuffer
        )
        let availableCount = prewarmedSessions.count + prewarmedSessionsInFlight
        guard availableCount < targetCount else { return }

        let remainingCapacity = targetCount - availableCount
        let workerLimit = urgent ? Constants.maxConcurrentUrgentPrewarms : Constants.maxConcurrentPrewarms
        let availableWorkers = max(0, workerLimit - prewarmedSessionsInFlight)
        let sessionsToStart = min(remainingCapacity, availableWorkers)
        guard sessionsToStart > 0 else { return }

        for _ in 0..<sessionsToStart {
            prewarmedSessionsInFlight += 1

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let session = ChatSession(id: UUID(), webViewModel: WebViewModel())
                session.webViewModel.prepareFreshConversationForPrewarm { [weak self] isReady in
                    guard let self = self else { return }
                    self.prewarmedSessionsInFlight = max(0, self.prewarmedSessionsInFlight - 1)

                    if isReady {
                        if let requestID = self.dequeuePendingNewChatRequest() {
                            #if DEBUG
                            print("[AppCoordinator] Delivering prewarmed session to queued request (\(requestID)). Remaining queued: \(self.pendingNewChatRequestQueue.count)")
                            #endif
                            self.appendAndActivateSession(session)
                        } else {
                            self.prewarmedSessions.append(session)
                            #if DEBUG
                            print("[AppCoordinator] Prewarmed session ready. Pool size: \(self.prewarmedSessions.count)")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("[AppCoordinator] Prewarm attempt failed. Scheduling retry.")
                        #endif
                        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.prewarmRetryDelay) { [weak self] in
                            self?.preparePrewarmedSessionsIfNeeded(urgent: !(self?.pendingNewChatRequestQueue.isEmpty ?? true))
                        }
                    }

                    self.preparePrewarmedSessionsIfNeeded(urgent: !self.pendingNewChatRequestQueue.isEmpty)
                }
            }
        }
    }

    private func takePrewarmedSession() -> ChatSession? {
        guard !prewarmedSessions.isEmpty else { return nil }
        return prewarmedSessions.removeFirst()
    }

    private func appendAndActivateSession(_ session: ChatSession) {
        chatSessions.append(session)
        activateSession(at: chatSessions.count - 1)
    }

    private func enqueuePendingNewChatRequest() -> UUID {
        let requestID = UUID()
        pendingNewChatRequestQueue.append(requestID)
        return requestID
    }

    @discardableResult
    private func dequeuePendingNewChatRequest() -> UUID? {
        guard !pendingNewChatRequestQueue.isEmpty else { return nil }
        let requestID = pendingNewChatRequestQueue.removeFirst()
        cancelFallback(for: requestID)
        return requestID
    }

    @discardableResult
    private func removePendingNewChatRequest(_ requestID: UUID) -> Bool {
        guard let index = pendingNewChatRequestQueue.firstIndex(of: requestID) else {
            return false
        }
        pendingNewChatRequestQueue.remove(at: index)
        cancelFallback(for: requestID)
        return true
    }

    private func scheduleFallbackLiveCreation(for requestID: UUID) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.removePendingNewChatRequest(requestID) else { return }

            #if DEBUG
            print("[AppCoordinator] Pending request fallback triggered (\(requestID)). Creating live session.")
            #endif

            let session = ChatSession(id: UUID(), webViewModel: WebViewModel())
            self.appendAndActivateSession(session)
            session.webViewModel.createFreshConversation()
            self.preparePrewarmedSessionsIfNeeded(urgent: !self.pendingNewChatRequestQueue.isEmpty)
        }

        pendingNewChatFallbackWorkItems[requestID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.pendingRequestFallbackDelay, execute: workItem)
    }

    private func cancelFallback(for requestID: UUID) {
        guard let workItem = pendingNewChatFallbackWorkItems.removeValue(forKey: requestID) else { return }
        workItem.cancel()
    }

    private func refreshChatBarIfVisible() {
        guard let bar = chatBar, bar.isVisible else { return }
        bar.orderOut(nil)
        chatBar = nil
        showChatBar()
    }

    private func isChatContext(window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        if window is ChatBarPanel { return true }
        if window.identifier?.rawValue == Constants.mainWindowIdentifier { return true }
        return windowContainsGemeloWebView(window)
    }

    private func windowContainsGemeloWebView(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        return containsGemeloWebView(in: contentView)
    }

    private func containsGemeloWebView(in view: NSView) -> Bool {
        if view is WKWebView {
            return true
        }

        for subview in view.subviews where containsGemeloWebView(in: subview) {
            return true
        }

        return false
    }

    private func shortcut(_ shortcut: LocalShortcut, matches event: NSEvent) -> Bool {
        let activeModifiers = event.modifierFlags.intersection(Constants.shortcutModifierMask)
        guard activeModifiers == shortcut.modifiers else { return false }
        guard let keyToken = Self.eventKeyToken(from: event) else { return false }
        return keyToken == shortcut.keyToken
    }

    private func loadLocalShortcutSettings() {
        newChatShortcut = Self.loadShortcut(
            for: .newLocalChatShortcut,
            defaultValue: Self.defaultNewLocalChatShortcut
        )
        switchChatShortcut = Self.loadShortcut(
            for: .switchLocalChatShortcut,
            defaultValue: Self.defaultSwitchLocalChatShortcut
        )
        closeChatShortcut = Self.loadShortcut(
            for: .closeLocalChatShortcut,
            defaultValue: Self.defaultCloseLocalChatShortcut
        )
        updateSystemCloseWindowCommandOverride()
    }

    private func updateSystemCloseWindowCommandOverride(attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 0 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            if self.applySystemCloseWindowCommandOverride() {
                return
            }

            if attempt < 5 {
                self.updateSystemCloseWindowCommandOverride(attempt: attempt + 1)
            }
        }
    }

    private func applySystemCloseWindowCommandOverride() -> Bool {
        guard let closeMenuItem = findSystemCloseWindowMenuItem() else { return false }

        if systemCloseMenuItem !== closeMenuItem {
            systemCloseMenuItem = closeMenuItem
            systemCloseMenuOriginalKeyEquivalent = closeMenuItem.keyEquivalent
            systemCloseMenuOriginalModifierMask = closeMenuItem.keyEquivalentModifierMask
        }

        if closeChatShortcut.normalized == Constants.systemCloseShortcut {
            closeMenuItem.keyEquivalent = ""
            closeMenuItem.keyEquivalentModifierMask = []
            return true
        }

        closeMenuItem.keyEquivalent = systemCloseMenuOriginalKeyEquivalent ?? Constants.systemCloseShortcutKeyEquivalent
        closeMenuItem.keyEquivalentModifierMask = systemCloseMenuOriginalModifierMask ?? Constants.systemCloseShortcutModifiers
        return true
    }

    private func findSystemCloseWindowMenuItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        return findMenuItem(in: mainMenu) { item in
            item.action == #selector(NSWindow.performClose(_:))
        }
    }

    private func findMenuItem(in menu: NSMenu, matching predicate: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if predicate(item) {
                return item
            }

            if let submenu = item.submenu, let match = findMenuItem(in: submenu, matching: predicate) {
                return match
            }
        }

        return nil
    }

    private static func loadShortcut(for key: UserDefaultsKeys, defaultValue: String) -> LocalShortcut {
        let storedValue = UserDefaults.standard.string(forKey: key.rawValue) ?? defaultValue
        let shortcut = parseShortcut(storedValue) ?? parseShortcut(defaultValue)!

        if storedValue != shortcut.normalized {
            UserDefaults.standard.set(shortcut.normalized, forKey: key.rawValue)
        }

        return shortcut
    }

    private static func parseShortcut(_ raw: String) -> LocalShortcut? {
        let tokens = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        var modifiers = Set<String>()
        var keyToken: String?

        for token in tokens {
            if let modifier = canonicalModifier(from: token) {
                modifiers.insert(modifier)
                continue
            }

            guard keyToken == nil, let normalizedKey = normalizeKeyToken(token) else {
                return nil
            }
            keyToken = normalizedKey
        }

        guard let keyToken else { return nil }

        let orderedModifiers = Constants.shortcutModifierOrder.filter { modifiers.contains($0) }
        let normalized = (orderedModifiers + [keyToken]).joined(separator: "+")

        return LocalShortcut(
            normalized: normalized,
            modifiers: modifierFlags(from: orderedModifiers),
            keyToken: keyToken
        )
    }

    private static func canonicalModifier(from token: String) -> String? {
        switch token {
        case "cmd", "command", "⌘":
            return "cmd"
        case "ctrl", "control", "^":
            return "ctrl"
        case "alt", "option", "opt", "⌥":
            return "alt"
        case "shift", "⇧":
            return "shift"
        default:
            return nil
        }
    }

    private static func normalizeKeyToken(_ token: String) -> String? {
        switch token {
        case "tab":
            return "tab"
        case "enter", "return":
            return "enter"
        case "esc", "escape":
            return "escape"
        case "space", "spacebar":
            return "space"
        default:
            guard token.count == 1, let character = token.first else { return nil }
            guard character.isLetter || character.isNumber else { return nil }
            return String(character)
        }
    }

    private static func modifierFlags(from orderedModifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []

        for modifier in orderedModifiers {
            switch modifier {
            case "cmd":
                flags.insert(.command)
            case "ctrl":
                flags.insert(.control)
            case "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                break
            }
        }

        return flags
    }

    private static func eventKeyToken(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 48: // Tab
            return "tab"
        case 36, 76: // Return, Enter
            return "enter"
        case 53: // Escape
            return "escape"
        case 49: // Space
            return "space"
        default:
            guard let raw = event.charactersIgnoringModifiers?.lowercased(), raw.count == 1,
                  let character = raw.first,
                  character.isLetter || character.isNumber
            else {
                return nil
            }
            return String(character)
        }
    }

    deinit {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}


extension AppCoordinator {
    struct ChatSession: Identifiable {
        let id: UUID
        let webViewModel: WebViewModel
    }

    private struct LocalShortcut {
        let normalized: String
        let modifiers: NSEvent.ModifierFlags
        let keyToken: String
    }

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemelo"
        static let prewarmedSessionTarget = 6
        static let prewarmedSessionBuffer = 2
        static let maxConcurrentPrewarms = 4
        static let maxConcurrentUrgentPrewarms = 6
        static let prewarmRetryDelay: TimeInterval = 0.2
        static let pendingRequestFallbackDelay: TimeInterval = 0.45
        static let systemCloseShortcut = "cmd+w"
        static let systemCloseShortcutKeyEquivalent = "w"
        static let systemCloseShortcutModifiers: NSEvent.ModifierFlags = [.command]

        static let shortcutModifierOrder = ["cmd", "ctrl", "alt", "shift"]
        static let shortcutModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    }

}
