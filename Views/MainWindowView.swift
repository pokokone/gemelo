//
//  MainWindowContent.swift
//  Gemelo
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit

struct MainWindowView: View {
    @Binding var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            GemeloWebView(webView: coordinator.webViewModel.wkWebView)
                .opacity(coordinator.webViewModel.isThinkingModeReady ? 1 : 0)

            if !coordinator.webViewModel.isThinkingModeReady {
                Color(nsColor: .windowBackgroundColor)
                ProgressView()
                    .controlSize(.small)
            }
        }
            .onAppear {
                coordinator.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
            .toolbar {
                if coordinator.canGoBack {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            coordinator.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("Back")
                    }
                }

                ToolbarItem(placement: .navigation) {
                    Button {
                        coordinator.closeCurrentChat()
                    } label: {
                        Image(systemName: "xmark.bubble")
                    }
                    .help("Close Current Chat (\(coordinator.closeChatShortcutHint))")
                }

                ToolbarItem(placement: .principal) {
                    HoverRevealChatSessionIndicator(
                        current: coordinator.currentChatNumber,
                        total: coordinator.totalChatCount
                    )
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        minimizeToPrompt()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Minimize to Prompt Panel")
                }
            }
    }

    private func minimizeToPrompt() {
        // Close main window and show chat bar
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || $0.title == AppCoordinator.Constants.mainWindowTitle }) {
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
        coordinator.showChatBar()
    }
}

private struct HoverRevealChatSessionIndicator: View {
    let current: Int
    let total: Int
    @State private var isHovering = false

    private var safeTotal: Int {
        max(total, 1)
    }

    var body: some View {
        ZStack {
            Color.clear
            Text("\(current) / \(safeTotal)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 0.92 : 0.0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .frame(width: 110, height: 24)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Chat \(current) / \(safeTotal)")
    }
}
