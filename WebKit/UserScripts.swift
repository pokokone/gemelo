//
//  UserScripts.swift
//  Gemelo
//
//  Created by alexcding on 2025-12-15.
//

import WebKit

/// Collection of user scripts injected into WKWebView
enum UserScripts {

    /// Message handler name for console log bridging
    static let consoleLogHandler = "consoleLog"

    /// Creates all user scripts to be injected into the WebView
    static func createAllScripts(inputFocusShortcut: String) -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            createIMEFixScript(),
            createInputFocusShortcutScript(defaultShortcut: inputFocusShortcut),
            createDefaultThinkingModeScript()
        ]

        #if DEBUG
        scripts.insert(createConsoleLogBridgeScript(), at: 0)
        #endif

        return scripts
    }

    /// Creates a script that bridges console.log to native Swift
    private static func createConsoleLogBridgeScript() -> WKUserScript {
        WKUserScript(
            source: consoleLogBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Creates the IME fix script that resolves the double-enter issue
    /// when using input method editors (e.g., Chinese, Japanese, Korean input)
    private static func createIMEFixScript() -> WKUserScript {
        WKUserScript(
            source: imeFixSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// Creates a script that focuses the prompt input when a configured key sequence is pressed
    private static func createInputFocusShortcutScript(defaultShortcut: String) -> WKUserScript {
        WKUserScript(
            source: inputFocusShortcutSource(defaultShortcut: defaultShortcut),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// Creates a script that switches response mode to Thinking on initial page load
    private static func createDefaultThinkingModeScript() -> WKUserScript {
        WKUserScript(
            source: defaultThinkingModeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    // MARK: - Script Sources

    /// JavaScript to bridge console.log to native Swift via WKScriptMessageHandler
    private static let consoleLogBridgeSource = """
    (function() {
        const originalLog = console.log;
        console.log = function(...args) {
            originalLog.apply(console, args);
            try {
                const message = args.map(arg => {
                    if (typeof arg === 'object') {
                        return JSON.stringify(arg, null, 2);
                    }
                    return String(arg);
                }).join(' ');
                window.webkit.messageHandlers.\(consoleLogHandler).postMessage(message);
            } catch (e) {}
        };
    })();
    """

    /// JavaScript to fix the IME double-enter issue on the chat page
    /// When using IME (e.g., Chinese/Japanese input), pressing Enter after completing
    /// composition would require a second Enter to send. This script detects when
    /// IME composition just ended and automatically clicks the send button.
    /// https://update.greasyfork.org/scripts/532717/阻止Gemini两次点击.user.js
    private static let imeFixSource = """
    (function() {
        'use strict';

        // IME state tracking
        let imeActive = false;
        let imeJustEnded = false;
        let lastImeEndTime = 0;
        const IME_BUFFER_TIME = 300; // Response time after IME ends (milliseconds)

        // Check if IME input just finished
        function justFinishedImeInput() {
            return imeJustEnded || (Date.now() - lastImeEndTime < IME_BUFFER_TIME);
        }

        // Handle IME composition events
        document.addEventListener('compositionstart', function(e) {
            console.log('[IME Debug] compositionstart:', {
                data: e.data,
                target: e.target?.tagName,
                previousImeActive: imeActive
            });
            imeActive = true;
            imeJustEnded = false;
        }, true);

        document.addEventListener('compositionupdate', function(e) {
            console.log('[IME Debug] compositionupdate:', {
                data: e.data,
                target: e.target?.tagName
            });
        }, true);

        document.addEventListener('compositionend', function(e) {
            console.log('[IME Debug] compositionend:', {
                data: e.data,
                target: e.target?.tagName,
                previousImeActive: imeActive
            });
            imeActive = false;
            imeJustEnded = true;
            lastImeEndTime = Date.now();
            console.log('[IME Debug] IME ended, setting imeJustEnded=true, lastImeEndTime=' + lastImeEndTime);
            setTimeout(() => {
                imeJustEnded = false;
                console.log('[IME Debug] Buffer time expired, imeJustEnded reset to false');
            }, IME_BUFFER_TIME);
        }, true);

        // Find and click the send button
        function findAndClickSendButton() {
            console.log('[IME Debug] findAndClickSendButton called');
            const selectors = [
                'button[type="submit"]',
                'button.send-button',
                'button.submit-button',
                '[aria-label="发送"]',
                '[aria-label="Send"]',
                'button:has(svg[data-icon="paper-plane"])',
                '#send-button',
            ];

            for (const selector of selectors) {
                const buttons = document.querySelectorAll(selector);
                console.log('[IME Debug] Checking selector:', selector, 'found:', buttons.length);
                for (const button of buttons) {
                    const isVisible = button.offsetParent !== null;
                    const isDisplayed = getComputedStyle(button).display !== 'none';
                    console.log('[IME Debug] Button check:', {
                        selector: selector,
                        disabled: button.disabled,
                        isVisible: isVisible,
                        isDisplayed: isDisplayed,
                        classList: button.className,
                        ariaLabel: button.getAttribute('aria-label')
                    });
                    if (button &&
                        !button.disabled &&
                        isVisible &&
                        isDisplayed) {
                        console.log('[IME Debug] Clicking button:', button);
                        button.click();
                        return true;
                    }
                }
            }

            // Fallback: try form submission
            const activeElement = document.activeElement;
            console.log('[IME Debug] No button found, trying form submission. Active element:', activeElement?.tagName);
            if (activeElement && (activeElement.tagName === 'TEXTAREA' || activeElement.tagName === 'INPUT')) {
                const form = activeElement.closest('form');
                if (form) {
                    console.log('[IME Debug] Found form, dispatching submit event');
                    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
                    return true;
                }
            }

            console.log('[IME Debug] No send button or form found');
            return false;
        }

        // Listen for Enter key
        document.addEventListener('keydown', function(e) {
            // Only log Enter key events to reduce noise
            if (e.key === 'Enter' || e.keyCode === 13) {
                console.log('[IME Debug] Enter keydown:', {
                    shiftKey: e.shiftKey,
                    ctrlKey: e.ctrlKey,
                    altKey: e.altKey,
                    imeActive: imeActive
                });
            }

            // Submit on Enter (but not Shift+Enter for new line, and not during IME composition)
            if ((e.key === 'Enter' || e.keyCode === 13) &&
                !e.shiftKey && !e.ctrlKey && !e.altKey &&
                !imeActive) {
                console.log('[IME Debug] Enter detected, attempting to click send button');
                if (findAndClickSendButton()) {
                    console.log('[IME Debug] Send button clicked successfully');
                    e.stopImmediatePropagation();
                    e.preventDefault();
                    return false;
                } else {
                    console.log('[IME Debug] Failed to find/click send button');
                }
            }
        }, true);

        // Enhance input elements
        function enhanceInputElement(input) {
            console.log('[IME Debug] Enhancing input element:', input.tagName, input.id, input.className);
            const originalKeyDown = input.onkeydown;

            input.onkeydown = function(e) {
                // Submit on Enter (but not Shift+Enter, and not during IME)
                if ((e.key === 'Enter' || e.keyCode === 13) &&
                    !e.shiftKey && !e.ctrlKey && !e.altKey &&
                    !imeActive) {
                    console.log('[IME Debug] Enhanced input: Enter detected');
                    if (findAndClickSendButton()) {
                        console.log('[IME Debug] Enhanced input: Send button clicked');
                        e.stopPropagation();
                        e.preventDefault();
                        return false;
                    }
                }
                if (originalKeyDown) return originalKeyDown.call(this, e);
            };
        }

        // Process existing and new input elements
        function processInputElements() {
            document.querySelectorAll('textarea, input[type="text"]').forEach(enhanceInputElement);
        }

        // Initial processing after page load
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
                setTimeout(processInputElements, 1000);
            });
        } else {
            setTimeout(processInputElements, 1000);
        }

        // Monitor DOM changes for new input elements
        if (window.MutationObserver) {
            const observer = new MutationObserver((mutations) => {
                mutations.forEach((mutation) => {
                    if (mutation.addedNodes && mutation.addedNodes.length > 0) {
                        mutation.addedNodes.forEach((node) => {
                            if (node.nodeType === 1) {
                                if (node.tagName === 'TEXTAREA' ||
                                    (node.tagName === 'INPUT' && node.type === 'text')) {
                                    enhanceInputElement(node);
                                }

                                const inputs = node.querySelectorAll ?
                                    node.querySelectorAll('textarea, input[type="text"]') : [];
                                if (inputs.length > 0) {
                                    inputs.forEach(enhanceInputElement);
                                }
                            }
                        });
                    }
                });
            });

            observer.observe(document.body, {
                childList: true,
                subtree: true
            });
        }
    })();
    """

    /// JavaScript to emulate Vimium-style "focus input" sequence (default: gi)
    private static func inputFocusShortcutSource(defaultShortcut: String) -> String {
        let escapedShortcut = defaultShortcut
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        return """
        (function() {
            'use strict';

            const DEFAULT_SHORTCUT = '\(escapedShortcut)';
            const KEY_TIMEOUT_MS = 900;
            let shortcut = normalizeShortcut(DEFAULT_SHORTCUT);
            let buffer = '';
            let lastKeyTime = 0;

            function normalizeShortcut(value) {
                const normalized = String(value || '')
                    .toLowerCase()
                    .replace(/[^a-z0-9]/g, '')
                    .slice(0, 4);
                return normalized || 'gi';
            }

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
                    const editableTypes = ['text', 'search', 'url', 'email', 'password', 'tel', 'number'];
                    return editableTypes.includes(type);
                }

                return element.getAttribute('role') === 'textbox';
            }

            function findInput() {
                const selectors = [
                    'div[contenteditable="true"][role="textbox"]',
                    'textarea',
                    'input[type="text"]',
                    'input[type="search"]',
                    'input:not([type])',
                    '[role="textbox"]',
                    '[contenteditable="true"]'
                ];

                for (const selector of selectors) {
                    const elements = document.querySelectorAll(selector);
                    for (const element of elements) {
                        if (isEditableElement(element) && isVisible(element)) {
                            return element;
                        }
                    }
                }
                return null;
            }

            function moveCaretToEnd(element) {
                if (!element || !element.isContentEditable) return;
                const selection = window.getSelection && window.getSelection();
                if (!selection) return;
                const range = document.createRange();
                range.selectNodeContents(element);
                range.collapse(false);
                selection.removeAllRanges();
                selection.addRange(range);
            }

            function focusPromptInput() {
                const input = findInput();
                if (!input) return false;

                if (typeof input.focus === 'function') {
                    input.focus({ preventScroll: true });
                }
                if (typeof input.click === 'function') {
                    input.click();
                }
                moveCaretToEnd(input);

                const active = document.activeElement;
                return active === input || (input.contains && input.contains(active));
            }

            window.__gemeloDesktopSetInputFocusShortcut = function(value) {
                shortcut = normalizeShortcut(value);
                buffer = '';
            };

            window.__gemeloDesktopFocusPromptInput = focusPromptInput;

            document.addEventListener('keydown', function(event) {
                if (event.defaultPrevented) return;
                if (event.metaKey || event.ctrlKey || event.altKey) return;
                if (event.isComposing) return;
                if (isEditableElement(event.target)) return;

                const key = String(event.key || '').toLowerCase();

                if (!/^[a-z0-9]$/.test(key)) {
                    buffer = '';
                    return;
                }

                const now = Date.now();
                if (now - lastKeyTime > KEY_TIMEOUT_MS) {
                    buffer = '';
                }
                lastKeyTime = now;
                buffer += key;

                if (!shortcut.startsWith(buffer)) {
                    buffer = key === shortcut.charAt(0) ? key : '';
                    return;
                }

                if (buffer === shortcut) {
                    buffer = '';
                    if (focusPromptInput()) {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        event.stopPropagation();
                    }
                }
            }, true);
        })();
        """
    }

    /// JavaScript to switch default response mode from Fast to Thinking
    private static let defaultThinkingModeSource = """
    (function() {
        'use strict';

        const THINKING_KEYWORDS = ['thinking', 'think', '思考', '推理', '深度思考'];
        const FAST_KEYWORDS = ['fast', '快速', '极速'];
        const MAX_ATTEMPTS = 300;
        const POLL_INTERVAL_MS = 60;
        const MENU_OPEN_DELAY_MS = 40;

        let attempts = 0;
        let completed = false;
        let waitingForMenu = false;
        let observer = null;
        let timer = null;

        function normalize(text) {
            return String(text || '')
                .toLowerCase()
                .replace(/\\s+/g, ' ')
                .trim();
        }

        function isDisplayable(element) {
            if (!(element instanceof HTMLElement) || !element.isConnected) return false;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (style.pointerEvents === 'none') return false;
            if (element.getAttribute('aria-disabled') === 'true') return false;
            if (element.hasAttribute('disabled')) return false;
            if (element.getAttribute('aria-hidden') === 'true') return false;
            if (element.closest('[aria-hidden=\"true\"]')) return false;
            return true;
        }

        function canInteract(element) {
            if (!isDisplayable(element)) return false;
            return true;
        }

        function hasKeyword(text, keywords) {
            const value = normalize(text);
            return keywords.some((keyword) => value.includes(keyword));
        }

        function includesThinking(text) {
            return hasKeyword(text, THINKING_KEYWORDS);
        }

        function includesFast(text) {
            return hasKeyword(text, FAST_KEYWORDS);
        }

        function findModeButton() {
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
        }

        function isThinkingAlreadyActive(button) {
            if (!button) return false;
            const labelNode =
                button.querySelector('[data-test-id=\"logo-pill-label-container\"] > span') ||
                button.querySelector('.logo-pill-label-container > span') ||
                button.querySelector('.input-area-switch-label > span') ||
                button.querySelector('.mdc-button__label > div > span') ||
                button.querySelector('.mdc-button__label > span');

            const text = normalize(
                (labelNode && labelNode.textContent) ||
                button.getAttribute('aria-label') ||
                button.getAttribute('title') ||
                button.textContent
            );

            if (!text) return false;
            return includesThinking(text) && !includesFast(text);
        }

        function findThinkingMenuItem() {
            const candidates = document.querySelectorAll(
                '[role=\"menuitem\"], button, a, div.mat-mdc-menu-item, li[role=\"option\"]'
            );

            for (const item of candidates) {
                if (!(item instanceof HTMLElement)) continue;
                if (!canInteract(item)) continue;
                const text = normalize(
                    item.textContent ||
                    item.getAttribute('aria-label') ||
                    item.getAttribute('title')
                );
                if (!includesThinking(text)) continue;
                if (includesFast(text)) continue;
                return item;
            }

            return null;
        }

        function complete() {
            completed = true;
            if (observer) observer.disconnect();
            if (timer) clearInterval(timer);
        }

        function trySetThinkingMode() {
            if (completed) return false;
            attempts += 1;

            const modeButton = findModeButton();
            if (modeButton && isThinkingAlreadyActive(modeButton)) {
                complete();
                return true;
            }

            const thinkingItem = findThinkingMenuItem();
            if (thinkingItem) {
                thinkingItem.click();
                setTimeout(trySetThinkingMode, MENU_OPEN_DELAY_MS);
            } else if (modeButton && !waitingForMenu) {
                waitingForMenu = true;
                modeButton.click();
                setTimeout(function() {
                    waitingForMenu = false;
                    trySetThinkingMode();
                }, MENU_OPEN_DELAY_MS);
            }

            if (attempts >= MAX_ATTEMPTS) {
                complete();
            }

            return false;
        }

        observer = new MutationObserver(function() {
            trySetThinkingMode();
        });

        function attachObserverIfPossible() {
            if (!document.body) return;
            observer.observe(document.body, { childList: true, subtree: true });
        }
        attachObserverIfPossible();
        document.addEventListener('DOMContentLoaded', attachObserverIfPossible, { once: true });

        timer = setInterval(function() {
            trySetThinkingMode();
        }, POLL_INTERVAL_MS);

        window.__gemeloDesktopEnsureThinkingMode = function() {
            trySetThinkingMode();
            const modeButton = findModeButton();
            return !!(modeButton && isThinkingAlreadyActive(modeButton));
        };
        trySetThinkingMode();
    })();
    """
}
