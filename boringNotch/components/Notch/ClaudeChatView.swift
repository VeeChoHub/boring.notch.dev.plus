//
//  ClaudeChatView.swift
//  boringNotch
//
//  Chat con Claude Code dentro il notch. Ogni messaggio è un `claude -p --resume` lanciato
//  dall'helper XPC (BoringNotchXPCHelper.runClaude): la sessione continua finché l'utente non scrive /clear.
//

import SwiftUI

struct ClaudeChatMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user, assistant, tool, error
    }

    var id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class ClaudeChatModel: ObservableObject {
    static let shared = ClaudeChatModel()

    // Messaggi e sessione persistiti: la chat sopravvive a chiusura del notch e riavvii dell'app
    @Published private(set) var messages: [ClaudeChatMessage] =
        (try? JSONDecoder().decode([ClaudeChatMessage].self, from: UserDefaults.standard.data(forKey: "claudeChatMessages") ?? Data())) ?? []
    {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(messages), forKey: "claudeChatMessages") }
    }
    private var sessionId: String? = UserDefaults.standard.string(forKey: "claudeChatSession") {
        didSet { UserDefaults.standard.set(sessionId, forKey: "claudeChatSession") }
    }

    @Published var isOpen = false // chat mostrata al posto della lista sessioni
    @Published private(set) var isRunning = false
    @Published var draft = ""

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("boringnotch.claude.chat"),
            object: nil, queue: .main) { [weak self] notification in
                guard let role = (notification.userInfo?["role"] as? String).flatMap(ClaudeChatMessage.Role.init),
                      let text = notification.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    self?.messages.append(ClaudeChatMessage(role: role, text: text))
                }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        if text == "/clear" {
            messages = []
            sessionId = nil
            return
        }
        messages.append(ClaudeChatMessage(role: .user, text: text))
        isRunning = true
        Task {
            if let session = await XPCHelperClient.shared.runClaude(text, sessionId: sessionId) {
                sessionId = session
            } else {
                messages.append(ClaudeChatMessage(role: .error, text: "Claude Code non è partito"))
            }
            isRunning = false
        }
    }
}

struct ClaudeChatView: View {
    @ObservedObject var chat = ClaudeChatModel.shared
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    chat.isOpen = false
                } label: {
                    Label("Sessioni", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                Spacer()
                Text("~ · /clear per ricominciare")
                    .foregroundStyle(.gray)
            }
            .font(.caption)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message)
                        }
                        if chat.isRunning {
                            ClaudeStateIcon(state: .working).frame(width: 14, height: 14)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo("bottom") }
                .onChange(of: chat.messages.count) {
                    withAnimation(.smooth) { proxy.scrollTo("bottom") }
                }
            }

            TextField(chat.isRunning ? "Claude sta lavorando…" : "Scrivi a Claude…", text: $chat.draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { chat.send() }
                .disabled(chat.isRunning)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        // Il notch aggiunge già ~12 pt ai lati e ~11 sotto: così il campo dista ~16 pt da tutti i bordi
        .padding(.horizontal, 4)
        .padding(.bottom, 5)
        .onAppear { inputFocused = true }
        .onChange(of: chat.isRunning) { _, running in
            if !running { inputFocused = true }
        }
    }
}

private struct MessageRow: View {
    let message: ClaudeChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.claude.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            // Markdown inline (grassetto, `codice`, link) mantenendo gli a capo
            Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                .foregroundStyle(.white)
                .textSelection(.enabled)
        case .tool:
            Text("⏺ \(message.text)")
                .font(.caption.monospaced())
                .foregroundStyle(.gray)
                .lineLimit(1)
        case .error:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
