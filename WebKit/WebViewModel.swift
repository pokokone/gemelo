//
//  WebViewModel.swift
//  Gemelo
//
//  Created by alexcding on 2025-12-15.
//

import WebKit
import Combine

/// Handles console.log messages from JavaScript
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

/// Observable wrapper around WKWebView with service-specific functionality
@Observable
class WebViewModel {

    // MARK: - Constants

    static let serviceURL = URL(string: "https://gemini.google.com/app")!
    static let defaultPageZoom: Double = 1.0
    static let defaultInputFocusShortcut: String = "gi"

    private static let serviceHost = "gemini.google.com"
    private static let serviceAppPath = "/app"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let minZoom: Double = 0.6
    private static let maxZoom: Double = 1.4
    private static let maxInputFocusShortcutLength = 4
    private static let newConversationRetryCount = 30
    private static let newConversationRetryDelay: TimeInterval = 0.25
    private static let thinkingModeRetryCount = 60
    private static let thinkingModeRetryDelay: TimeInterval = 0.06
    private static let thinkingModeRecoveryCycles = 2
    private static let thinkingModeStabilityChecks = 3
    private static let thinkingModeStabilityDelay: TimeInterval = 0.12
    private static let focusInputRetryCount = 40
    private static let focusInputRetryDelay: TimeInterval = 0.15
    private static let ensureThinkingModeScript = """
    (() => {
        const FAST_KEYWORDS = ['fast', '快速', '极速'];
        const THINKING_KEYWORDS = ['thinking', 'think', '思考', '推理', '深度思考'];

        const normalize = (value) => String(value || '')
            .toLowerCase()
            .replace(/\\s+/g, ' ')
            .trim();

        const isDisplayable = (element) => {
            if (!element || !element.isConnected) return false;
            if (!(element instanceof HTMLElement)) return false;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (style.pointerEvents === 'none') return false;
            if (element.getAttribute('aria-disabled') === 'true') return false;
            if (element.hasAttribute('disabled')) return false;
            if (element.getAttribute('aria-hidden') === 'true') return false;
            if (element.closest('[aria-hidden=\"true\"]')) return false;
            return true;
        };

        const canInteract = (element) => {
            if (!isDisplayable(element)) return false;
            return true;
        };

        const findModeButton = () => {
            const selectors = [
                'button[data-test-id=\"bard-mode-menu-button\"]',
                'button[aria-label*=\"mode picker\" i]',
                'bard-mode-switcher button.input-area-switch',
                'bard-mode-switcher button.mat-mdc-menu-trigger',
                '.model-picker-container bard-mode-switcher button'
            ];

            for (const selector of selectors) {
                const button = document.querySelector(selector);
                if (button && canInteract(button)) return button;
            }

            return null;
        };

        const getModeLabelText = (button) => {
            if (!button) return '';

            const labelSelectors = [
                '[data-test-id=\"logo-pill-label-container\"] > span',
                '.logo-pill-label-container > span',
                '.input-area-switch-label > span',
                '.mdc-button__label > div > span',
                '.mdc-button__label > span'
            ];

            for (const selector of labelSelectors) {
                const labelNode = button.querySelector(selector);
                if (!labelNode) continue;
                const text = normalize(labelNode.textContent);
                if (text) return text;
            }

            return normalize(
                button.getAttribute('aria-label') ||
                button.getAttribute('title') ||
                button.textContent
            );
        };

        const hasKeyword = (text, keywords) => keywords.some((keyword) => text.includes(keyword));

        const isThinkingMode = (button) => {
            const text = getModeLabelText(button);
            if (!text) return false;
            return hasKeyword(text, THINKING_KEYWORDS) && !hasKeyword(text, FAST_KEYWORDS);
        };

        const findThinkingMenuItem = () => {
            const candidates = document.querySelectorAll(
                '[role=\"menuitem\"], button.mat-mdc-menu-item, button[mat-menu-item], li[role=\"option\"], .mat-mdc-menu-content button'
            );

            for (const item of candidates) {
                if (!(item instanceof HTMLElement)) continue;
                if (!canInteract(item)) continue;

                const text = normalize(
                    item.textContent ||
                    item.getAttribute('aria-label') ||
                    item.getAttribute('title')
                );
                if (!text) continue;

                const matchesThinking = hasKeyword(text, THINKING_KEYWORDS);
                const matchesFast = hasKeyword(text, FAST_KEYWORDS);
                if (matchesThinking && !matchesFast) return item;
            }

            return null;
        };

        const modeButton = findModeButton();
        if (!modeButton) return false;
        if (isThinkingMode(modeButton)) return true;

        const thinkingItem = findThinkingMenuItem();
        if (thinkingItem) {
            thinkingItem.click();
            return false;
        }

        const expanded = modeButton.getAttribute('aria-expanded') === 'true';
        if (!expanded) {
            modeButton.click();
        }

        return false;
    })()
    """
    private static let currentModeStateScript = """
    (() => {
        const FAST_KEYWORDS = ['fast', '快速', '极速'];
        const THINKING_KEYWORDS = ['thinking', 'think', '思考', '推理', '深度思考'];

        const normalize = (value) => String(value || '')
            .toLowerCase()
            .replace(/\\s+/g, ' ')
            .trim();
        const hasKeyword = (text, keywords) => keywords.some((keyword) => text.includes(keyword));

        const modeButton =
            document.querySelector('button[data-test-id=\"bard-mode-menu-button\"]') ||
            document.querySelector('button[aria-label*=\"mode picker\" i]') ||
            document.querySelector('bard-mode-switcher button.input-area-switch') ||
            document.querySelector('bard-mode-switcher button.mat-mdc-menu-trigger') ||
            document.querySelector('.model-picker-container bard-mode-switcher button');

        if (!modeButton) return 'unknown';

        const labelNode =
            modeButton.querySelector('[data-test-id=\"logo-pill-label-container\"] > span') ||
            modeButton.querySelector('.logo-pill-label-container > span') ||
            modeButton.querySelector('.input-area-switch-label > span') ||
            modeButton.querySelector('.mdc-button__label > div > span') ||
            modeButton.querySelector('.mdc-button__label > span');

        const text = normalize(
            (labelNode && labelNode.textContent) ||
            modeButton.getAttribute('aria-label') ||
            modeButton.getAttribute('title') ||
            modeButton.textContent
        );
        if (!text) return 'unknown';

        const hasFast = hasKeyword(text, FAST_KEYWORDS);
        const hasThinking = hasKeyword(text, THINKING_KEYWORDS);
        if (hasThinking && !hasFast) return 'thinking';
        if (hasFast) return 'fast';
        return 'unknown';
    })()
    """
    private static let newConversationScript = """
    (() => {
        const normalize = (value) => (value || "").trim().toLowerCase();
        const labels = ["new chat", "new conversation", "new prompt", "新聊天", "新的聊天", "新对话", "新会话"];

        const isVisible = (element) => {
            if (!element || !element.isConnected) return false;
            const style = window.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden") return false;
            if (style.pointerEvents === "none") return false;
            if (element.getAttribute("aria-disabled") === "true") return false;
            if (element.hasAttribute("disabled")) return false;
            if (element.getAttribute("aria-hidden") === "true") return false;
            if (element.closest('[aria-hidden="true"]')) return false;
            return true;
        };

        const matchesNewChat = (element) => {
            const haystack = [
                normalize(element.getAttribute("aria-label")),
                normalize(element.getAttribute("title")),
                normalize(element.getAttribute("data-testid")),
                normalize(element.textContent).slice(0, 80)
            ].join(" ");

            return labels.some((label) => haystack.includes(label)) || haystack.includes("new-chat");
        };

        for (const element of document.querySelectorAll("button, [role='button'], a")) {
            if (!isVisible(element)) continue;
            if (!matchesNewChat(element)) continue;
            element.click();
            return true;
        }

        const appLink = document.querySelector("a[href='/app'], a[href='/app?hl=en']");
        if (appLink && isVisible(appLink)) {
            appLink.click();
            return true;
        }

        if (location.pathname.startsWith("/app/")) {
            location.href = "https://gemini.google.com/app";
        }

        return false;
    })()
    """
    private static let focusInputScript = """
    (() => {
        function isVisible(element) {
            if (!(element instanceof HTMLElement)) return false;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
        }

        function isEditableElement(element) {
            if (!element || !(element instanceof HTMLElement)) return false;
            if (element.isContentEditable) return true;

            const tag = element.tagName;
            if (tag === 'TEXTAREA') return true;
            if (tag === 'INPUT') {
                const type = (element.getAttribute('type') || 'text').toLowerCase();
                return ['text', 'search', 'url', 'email', 'password', 'tel', 'number'].includes(type);
            }

            return element.getAttribute('role') === 'textbox';
        }

        function findInput() {
            const selectors = [
                'div[contenteditable=\"true\"][role=\"textbox\"]',
                'textarea',
                'input[type=\"text\"]',
                'input[type=\"search\"]',
                'input:not([type])',
                '[role=\"textbox\"]',
                '[contenteditable=\"true\"]'
            ];

            for (const selector of selectors) {
                const elements = document.querySelectorAll(selector);
                for (const element of elements) {
                    if (isEditableElement(element) && isVisible(element)) return element;
                }
            }
            return null;
        }

        function focusInput() {
            if (typeof window.__gemeloDesktopFocusPromptInput === 'function') {
                try {
                    if (window.__gemeloDesktopFocusPromptInput()) return true;
                } catch (e) {}
            }

            const input = findInput();
            if (!input) return false;

            if (typeof input.focus === 'function') input.focus({ preventScroll: true });
            if (typeof input.click === 'function') input.click();

            if (input.isContentEditable) {
                const selection = window.getSelection && window.getSelection();
                if (selection) {
                    const range = document.createRange();
                    range.selectNodeContents(input);
                    range.collapse(false);
                    selection.removeAllRanges();
                    selection.addRange(range);
                }
            }

            const active = document.activeElement;
            return active === input || (input.contains && input.contains(active));
        }

        return focusInput();
    })()
    """

    // MARK: - Public Properties

    let wkWebView: WKWebView
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isAtHome: Bool = true
    private(set) var isThinkingModeReady: Bool = false

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private let consoleLogHandler = ConsoleLogHandler()

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createWebView(consoleLogHandler: consoleLogHandler)
        setupObservers()
        loadHome()
    }

    // MARK: - Navigation

    func loadHome() {
        isAtHome = true
        canGoBack = false
        isThinkingModeReady = false
        wkWebView.load(URLRequest(url: Self.serviceURL))
    }

    func goBack() {
        isAtHome = false
        wkWebView.goBack()
    }

    func goForward() {
        wkWebView.goForward()
    }

    func reload() {
        wkWebView.reload()
    }

    func createFreshConversation() {
        isThinkingModeReady = false
        prepareFreshConversationForPrewarm { [weak self] _ in
            self?.focusPromptInput()
        }
    }

    func prepareFreshConversationForPrewarm(completion: @escaping (Bool) -> Void) {
        isThinkingModeReady = false
        if !Self.isGemeloAppURL(wkWebView.url) {
            loadHome()
        }

        clickNewChatButton(retriesRemaining: Self.newConversationRetryCount) { [weak self] _ in
            guard let self = self else {
                completion(false)
                return
            }
            self.ensureThinkingMode(completion: completion)
        }
    }

    // MARK: - Zoom

    func zoomIn() {
        let newZoom = min((wkWebView.pageZoom * 100 + 1).rounded() / 100, Self.maxZoom)
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = max((wkWebView.pageZoom * 100 - 1).rounded() / 100, Self.minZoom)
        setZoom(newZoom)
    }

    func resetZoom() {
        setZoom(Self.defaultPageZoom)
    }

    // MARK: - Input Focus Shortcut

    func updateFocusInputShortcut(_ shortcut: String) {
        let normalized = Self.normalizeFocusInputShortcut(shortcut)
        UserDefaults.standard.set(normalized, forKey: UserDefaultsKeys.focusInputShortcut.rawValue)

        let escapedShortcut = normalized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let script = """
        window.__gemeloDesktopSetInputFocusShortcut && window.__gemeloDesktopSetInputFocusShortcut('\(escapedShortcut)');
        """
        wkWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    func focusPromptInput() {
        focusPromptInput(retriesRemaining: Self.focusInputRetryCount)
    }

    func ensureThinkingMode(completion: ((Bool) -> Void)? = nil) {
        let finish = completion ?? { _ in }
        evaluateCurrentModeState { [weak self] state in
            guard let self = self else {
                finish(false)
                return
            }

            if state == .thinking {
                self.verifyThinkingModeStability(
                    checksRemaining: Self.thinkingModeStabilityChecks,
                    delay: Self.thinkingModeStabilityDelay
                ) { [weak self] stable in
                    guard let self = self else {
                        finish(false)
                        return
                    }

                    if stable {
                        self.isThinkingModeReady = true
                        finish(true)
                        return
                    }

                    self.isThinkingModeReady = false
                    self.ensureThinkingMode(
                        retriesRemaining: Self.thinkingModeRetryCount,
                        recoveryCyclesRemaining: Self.thinkingModeRecoveryCycles,
                        completion: finish
                    )
                }
                return
            }

            self.isThinkingModeReady = false
            self.ensureThinkingMode(
                retriesRemaining: Self.thinkingModeRetryCount,
                recoveryCyclesRemaining: Self.thinkingModeRecoveryCycles,
                completion: finish
            )
        }
    }

    static func normalizeFocusInputShortcut(_ value: String) -> String {
        let normalized = String(
            value
                .lowercased()
                .filter { character in
                    character.unicodeScalars.allSatisfy { $0.isASCII } &&
                    (character.isLetter || character.isNumber)
                }
                .prefix(maxInputFocusShortcutLength)
        )

        return normalized.isEmpty ? defaultInputFocusShortcut : normalized
    }

    private func setZoom(_ zoom: Double) {
        wkWebView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: UserDefaultsKeys.pageZoom.rawValue)
    }

    private static func isGemeloAppURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host == serviceHost && url.path.hasPrefix(serviceAppPath)
    }

    private func clickNewChatButton(retriesRemaining: Int, completion: @escaping (Bool) -> Void) {
        guard retriesRemaining > 0 else {
            completion(false)
            return
        }

        wkWebView.evaluateJavaScript(Self.newConversationScript) { [weak self] result, _ in
            guard let self = self else {
                completion(false)
                return
            }
            if let clicked = result as? Bool, clicked {
                completion(true)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.newConversationRetryDelay) { [weak self] in
                self?.clickNewChatButton(retriesRemaining: retriesRemaining - 1, completion: completion)
            }
        }
    }

    private func ensureThinkingMode(
        retriesRemaining: Int,
        recoveryCyclesRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard retriesRemaining > 0 else {
            evaluateCurrentModeState { [weak self] state in
                guard let self = self else {
                    completion(false)
                    return
                }

                if state == .fast, recoveryCyclesRemaining > 0 {
                    #if DEBUG
                    print("[WebView] Thinking mode not ready at cycle boundary (state: \(state), retries restarting, remaining cycles: \(recoveryCyclesRemaining - 1))")
                    #endif
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.thinkingModeRetryDelay) { [weak self] in
                        self?.ensureThinkingMode(
                            retriesRemaining: Self.thinkingModeRetryCount,
                            recoveryCyclesRemaining: recoveryCyclesRemaining - 1,
                            completion: completion
                        )
                    }
                    return
                }

                let isThinkingReady = state == .thinking
                self.isThinkingModeReady = true
                #if DEBUG
                if isThinkingReady {
                    print("[WebView] Thinking mode ready.")
                } else {
                    print("[WebView] Falling back to ready state without confirmed thinking mode (state: \(state)).")
                }
                #endif
                completion(isThinkingReady)
            }
            return
        }

        wkWebView.evaluateJavaScript(Self.ensureThinkingModeScript) { [weak self] result, _ in
            guard let self = self else {
                completion(false)
                return
            }

            if let isThinking = result as? Bool, isThinking {
                self.evaluateCurrentModeState { [weak self] state in
                    guard let self = self else {
                        completion(false)
                        return
                    }

                    if state == .thinking {
                        self.verifyThinkingModeStability(
                            checksRemaining: Self.thinkingModeStabilityChecks,
                            delay: Self.thinkingModeStabilityDelay
                        ) { [weak self] stable in
                            guard let self = self else {
                                completion(false)
                                return
                            }

                            if stable {
                                self.isThinkingModeReady = true
                                #if DEBUG
                                print("[WebView] Thinking mode confirmed.")
                                #endif
                                completion(true)
                                return
                            }

                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.thinkingModeRetryDelay) { [weak self] in
                                self?.ensureThinkingMode(
                                    retriesRemaining: retriesRemaining - 1,
                                    recoveryCyclesRemaining: recoveryCyclesRemaining,
                                    completion: completion
                                )
                            }
                        }
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.thinkingModeRetryDelay) { [weak self] in
                        self?.ensureThinkingMode(
                            retriesRemaining: retriesRemaining - 1,
                            recoveryCyclesRemaining: recoveryCyclesRemaining,
                            completion: completion
                        )
                    }
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.thinkingModeRetryDelay) { [weak self] in
                self?.ensureThinkingMode(
                    retriesRemaining: retriesRemaining - 1,
                    recoveryCyclesRemaining: recoveryCyclesRemaining,
                    completion: completion
                )
            }
        }
    }

    private func verifyThinkingModeStability(
        checksRemaining: Int,
        delay: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard checksRemaining > 0 else {
            completion(false)
            return
        }

        evaluateCurrentModeState { [weak self] state in
            guard let self = self else {
                completion(false)
                return
            }

            guard state == .thinking else {
                completion(false)
                return
            }

            if checksRemaining == 1 {
                completion(true)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyThinkingModeStability(
                    checksRemaining: checksRemaining - 1,
                    delay: delay,
                    completion: completion
                )
            }
        }
    }

    private func evaluateCurrentModeState(completion: @escaping (ModeState) -> Void) {
        wkWebView.evaluateJavaScript(Self.currentModeStateScript) { result, _ in
            guard let stateString = result as? String else {
                completion(.unknown)
                return
            }

            switch stateString {
            case "thinking":
                completion(.thinking)
            case "fast":
                completion(.fast)
            default:
                completion(.unknown)
            }
        }
    }

    private func focusPromptInput(retriesRemaining: Int) {
        guard retriesRemaining > 0 else { return }

        if let window = wkWebView.window, window.firstResponder !== wkWebView {
            window.makeFirstResponder(wkWebView)
        }

        wkWebView.evaluateJavaScript(Self.focusInputScript) { [weak self] result, _ in
            guard let self = self else { return }
            if let focused = result as? Bool, focused {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusInputRetryDelay) { [weak self] in
                self?.focusPromptInput(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    // MARK: - Private Setup

    private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let savedInputFocusShortcut = UserDefaults.standard.string(forKey: UserDefaultsKeys.focusInputShortcut.rawValue)
        let inputFocusShortcut = normalizeFocusInputShortcut(savedInputFocusShortcut ?? defaultInputFocusShortcut)
        if savedInputFocusShortcut != inputFocusShortcut {
            UserDefaults.standard.set(inputFocusShortcut, forKey: UserDefaultsKeys.focusInputShortcut.rawValue)
        }

        // Add user scripts
        for script in UserScripts.createAllScripts(inputFocusShortcut: inputFocusShortcut) {
            configuration.userContentController.addUserScript(script)
        }

        // Register console log message handler (debug only)
        #if DEBUG
        configuration.userContentController.add(consoleLogHandler, name: UserScripts.consoleLogHandler)
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = userAgent

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = savedZoom > 0 ? savedZoom : defaultPageZoom

        return webView
    }

    private func setupObservers() {
        backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoBack = !self.isAtHome && webView.canGoBack
            }
        }

        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoForward = webView.canGoForward
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentURL = webView.url else { return }

                let isGemeloApp = Self.isGemeloAppURL(currentURL)

                if isGemeloApp {
                    self.isAtHome = true
                    self.canGoBack = false
                } else {
                    self.isAtHome = false
                    self.canGoBack = webView.canGoBack
                    // Do not block non-chat pages (e.g. Google account login) behind thinking-mode gating.
                    self.isThinkingModeReady = true
                }
            }
        }
    }

    private enum ModeState {
        case thinking
        case fast
        case unknown
    }
}
