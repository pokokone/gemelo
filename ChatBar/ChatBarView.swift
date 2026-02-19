//
//  ChatBarContent.swift
//  Gemelo
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

struct ChatBarView: View {
    let webView: WKWebView
    let onExpandToMain: () -> Void

    /// Calculate button offset based on screen height
    /// MacBook Air 13" (~900pt): (-6, -2), 1080p (1080pt): (-4, 0)
    private var buttonOffset: CGSize {
        let screenHeight = NSScreen.main?.frame.height ?? 900
        // Interpolate: 900pt -> (-6, -2), 1080pt -> (-4, 0)
        let t = (screenHeight - 900) / 180  // 0 at 900pt, 1 at 1080pt
        let xOffset = -6.0 + t * 2.0
        let yOffset = -2.0 + t * 2.0
        return CGSize(width: xOffset, height: yOffset)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GemeloWebView(webView: webView)

            Button(action: onExpandToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .offset(buttonOffset)
        }
    }
}
