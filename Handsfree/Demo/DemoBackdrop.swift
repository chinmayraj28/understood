//
//  DemoBackdrop.swift
//  Handsfree
//
//  Demo mode only (`--demo --backdrop`): a neutral practice screen behind the
//  overlay, so recordings and design screenshots show a plain mock chat app
//  instead of whatever private windows are open on the Mac. It is a generic
//  mock, not a copy of any real app. Its controls sit exactly where DemoScript
//  sends the simulated pointer. New for Handsfree.
//

import AppKit
import Combine
import SwiftUI

/// What the mock app shows; the demo updates it as the simulated hands act.
@MainActor
final class DemoBackdropModel: ObservableObject {
    @Published var searchText = ""
    @Published var composerText = ""
    @Published var selectedChatIndex: Int?
    @Published var sentMessage: String?

    private enum Field { case none, search, composer }
    private var focusedField: Field = .none
    private let searchWord = "Amma"
    private let message = "running late, ten minutes"

    func reset() {
        searchText = ""
        composerText = ""
        selectedChatIndex = nil
        sentMessage = nil
        focusedField = .none
    }

    func click(atTopLeft point: CGPoint, screen: CGSize) {
        if DemoLayout.searchFieldRect(screen: screen).contains(point) {
            focusedField = .search
        } else if DemoLayout.chatRowRect(screen: screen, index: 0).contains(point) {
            selectedChatIndex = 0
            focusedField = .none
        } else if DemoLayout.composerRect(screen: screen).contains(point) {
            focusedField = .composer
        } else if DemoLayout.sendButtonRect(screen: screen).contains(point), !composerText.isEmpty {
            sentMessage = composerText
            composerText = ""
            focusedField = .none
        }
    }

    func type(characterCount: Int) {
        switch focusedField {
        case .search: searchText = String(searchWord.prefix(characterCount))
        case .composer: composerText = String(message.prefix(characterCount))
        case .none: break
        }
    }
}

/// A full-screen window under the overlay. It takes clicks itself, so a stray
/// click during a recording cannot reach a hidden app underneath.
final class DemoBackdropWindow: NSWindow {
    init(screen: NSScreen, model: DemoBackdropModel) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        // Above the Dock (so a recording shows none of the Mac's own apps), below the menu bar.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let hostingView = NSHostingView(rootView: MockChatScreen(screenSize: screen.frame.size, model: model))
        hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = hostingView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MockChatScreen: View {
    let screenSize: CGSize
    @ObservedObject var model: DemoBackdropModel

    private let chats: [(name: String, preview: String, time: String, color: Color)] = [
        ("Amma", "See you at dinner?", "18:02", Color(hex: "#E07A5F")),
        ("Amma Work", "Invoice attached", "17:40", Color(hex: "#3D7EA6")),
        ("Priya Shah", "Thanks for today!", "Tue", Color(hex: "#81B29A")),
        ("Book club", "Next week: chapter 9", "Mon", Color(hex: "#9C89B8")),
    ]
    private let mockBlue = Color(hex: "#2F6FED")

    var body: some View {
        let window = DemoLayout.windowRect(screen: screenSize)
        let sidebar = DemoLayout.sidebarRect(screen: screenSize)
        let search = DemoLayout.searchFieldRect(screen: screenSize)
        let composer = DemoLayout.composerRect(screen: screenSize)
        let send = DemoLayout.sendButtonRect(screen: screenSize)

        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: "#C6D0DC"), Color(hex: "#E8E2D6")], startPoint: .topLeading, endPoint: .bottomTrailing)

            // Window.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)

            // Title bar.
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(hex: "#D5D5DA")).frame(width: 12, height: 12) }
                Spacer()
                Text(model.selectedChatIndex == nil ? "Chats" : chats[0].name)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "#3A3A40"))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(width: window.width, height: DemoLayout.titleBarHeight)
            .offset(x: window.minX, y: window.minY)

            // Sidebar.
            Rectangle().fill(Color(hex: "#F4F4F6"))
                .frame(width: sidebar.width, height: sidebar.height)
                .offset(x: sidebar.minX, y: sidebar.minY)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: "#8A8A93"))
                Text(model.searchText.isEmpty ? "Search" : model.searchText)
                    .foregroundStyle(model.searchText.isEmpty ? Color(hex: "#8A8A93") : Color(hex: "#1C1C1F"))
                Spacer()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .frame(width: search.width, height: search.height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#DADAE0"))))
            .offset(x: search.minX, y: search.minY)

            ForEach(Array(chats.enumerated()), id: \.offset) { index, chat in
                let row = DemoLayout.chatRowRect(screen: screenSize, index: index)
                HStack(spacing: 10) {
                    Circle().fill(chat.color).frame(width: 36, height: 36)
                        .overlay(Text(String(chat.name.prefix(1))).font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: "#1C1C1F"))
                        Text(index == 0 && model.sentMessage != nil ? "You: \(model.sentMessage!)" : chat.preview)
                            .font(.system(size: 12)).foregroundStyle(Color(hex: "#6E6E78")).lineLimit(1)
                    }
                    Spacer()
                    Text(chat.time).font(.system(size: 11)).foregroundStyle(Color(hex: "#8A8A93"))
                }
                .padding(.horizontal, 14)
                .frame(width: row.width, height: row.height)
                .background(model.selectedChatIndex == index ? mockBlue.opacity(0.12) : Color.clear)
                .opacity(model.searchText.count >= 2 && !chat.name.lowercased().hasPrefix(model.searchText.lowercased()) ? 0.25 : 1)
                .offset(x: row.minX, y: row.minY)
            }

            // Conversation.
            if model.selectedChatIndex != nil {
                bubble("Are you on your way?", outgoing: false)
                    .offset(x: sidebar.maxX + 24, y: window.minY + DemoLayout.titleBarHeight + 28)
                if let sent = model.sentMessage {
                    bubble(sent, outgoing: true)
                        .frame(width: window.maxX - sidebar.maxX - 48, alignment: .trailing)
                        .offset(x: sidebar.maxX + 24, y: window.minY + DemoLayout.titleBarHeight + 84)
                }
            } else {
                Text("Choose a chat")
                    .font(.system(size: 14)).foregroundStyle(Color(hex: "#9A9AA3"))
                    .frame(width: window.maxX - sidebar.maxX, height: window.height - DemoLayout.titleBarHeight)
                    .offset(x: sidebar.maxX, y: window.minY + DemoLayout.titleBarHeight)
            }

            // Composer and Send.
            Text(model.composerText.isEmpty ? "Message" : model.composerText)
                .font(.system(size: 14))
                .foregroundStyle(model.composerText.isEmpty ? Color(hex: "#8A8A93") : Color(hex: "#1C1C1F"))
                .padding(.horizontal, 12)
                .frame(width: composer.width, height: composer.height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: composer.height / 2).fill(Color(hex: "#F4F4F6")).overlay(RoundedRectangle(cornerRadius: composer.height / 2).stroke(Color(hex: "#DADAE0"))))
                .offset(x: composer.minX, y: composer.minY)

            Text("Send")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: send.width, height: send.height)
                .background(Capsule().fill(mockBlue))
                .offset(x: send.minX, y: send.minY)
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(outgoing ? Color.white : Color(hex: "#1C1C1F"))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(outgoing ? mockBlue : Color(hex: "#EDEDF0")))
    }
}
