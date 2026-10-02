//
//  ClaudeSessionsView.swift
//  boringNotch
//
//  Sessioni Claude Code aperte (stato inviato da claude-hook.js).
//

import SwiftUI

extension Color {
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255) // arancione del logo e della mascotte
    static let aquaGreen = Color(red: 77 / 255, green: 217 / 255, blue: 166 / 255) // verde acqua (.teal di sistema è turchese)
}

struct ClaudeStateIcon: View {
    let state: ClaudeState

    var body: some View {
        Group {
            switch state {
            case .working:
                // TimelineView invece di repeatForever: non oscilla quando il notch cambia dimensione
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                        .padding(2)
                }
            case .question:
                Image(systemName: "questionmark.circle.fill").resizable().foregroundStyle(.yellow)
            case .permission:
                Image(systemName: "pause.circle.fill").resizable().foregroundStyle(Color.aquaGreen)
            case .done:
                Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(Color.aquaGreen)
            case .idle:
                Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(.gray)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct ClaudeSessionsView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var chat = ClaudeChatModel.shared

    private let labels: [ClaudeState: String] = [
        .working: "Al lavoro", .done: "Completata", .question: "Ti fa una domanda", .permission: "Aspetta un permesso", .idle: "In attesa",
    ]

    var body: some View {
        if chat.isOpen {
            ClaudeChatView()
        } else {
            sessionsPage
        }
    }

    @ViewBuilder
    private var sessionsPage: some View {
        // Solo 3 (quante ne entrano nel notch): prima le più urgenti, poi le più recenti
        let sessions = coordinator.claudeSessions.sorted {
            ($0.value.state.rawValue, $0.value.since) > ($1.value.state.rawValue, $1.value.since)
        }.prefix(3)
        // Niente ScrollView: l'altezza del notch (claudeOpenNotchSize) è calcolata per limiti + 3 sessioni + bottone
        VStack(spacing: 6) {
            // GeometryReader e non containerRelativeFrame: il notch prende la larghezza dal contenuto,
            // containerRelativeFrame la calcolava sulla finestra intera e il notch usciva dai bordi
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Image("claude-mascot")
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * 0.34, height: 70)
                    limits
                        .frame(width: geo.size.width * 0.66)
                }
            }
            .frame(height: 74)
            .padding(.bottom, 4)

            if sessions.isEmpty {
                Text("Nessuna sessione Claude Code aperta")
                    .foregroundStyle(.gray)
                    .padding(.top, 8)
            }
            ForEach(sessions, id: \.key) { _, session in
                HStack(spacing: 10) {
                    ClaudeStateIcon(state: session.state).frame(width: 18, height: 18)
                    Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(labels[session.state] ?? "")
                        .foregroundStyle(.gray)
                    Text(session.since, style: .relative)
                        .foregroundStyle(.gray)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            // Fissato in basso, nel posto che avrebbe con 3 sessioni
            Spacer(minLength: 0)
            Button {
                chat.isOpen = true
                // Click dentro al notch: la finestra può diventare key (canBecomeKey segue chat.isOpen) per scrivere
                NSApp.currentEvent?.window?.makeKey()
            } label: {
                Label(chat.messages.isEmpty ? "Nuova Sessione" : "Continua la chat",
                      systemImage: chat.messages.isEmpty ? "plus.bubble" : "bubble.left.and.bubble.right")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.claude.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        // Stessi margini della chat (~16 pt dai bordi del notch)
        .padding(.horizontal, 4)
        .padding(.bottom, 5)
    }

    @ViewBuilder
    private var limits: some View {
        let limits = coordinator.claudeLimits
        if limits?.fiveHour == nil && limits?.sevenDay == nil {
            Text("Limiti disponibili dopo il prossimo messaggio di Claude")
                .font(.caption)
                .foregroundStyle(.gray)
        } else {
            VStack(spacing: 10) {
                if let limit = limits?.fiveHour { LimitRow(title: "Sessione corrente", limit: limit) }
                if let limit = limits?.sevenDay { LimitRow(title: "Settimana (tutti i modelli)", limit: limit) }
            }
        }
    }
}

private struct LimitRow: View {
    let title: String
    let limit: ClaudeLimit

    var body: some View {
        let reset = Date(timeIntervalSince1970: limit.resetsAt)
        let used = limit.used
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold().foregroundStyle(.white)
                Spacer()
                Text("\(Int(used.rounded()))% · reset \(reset.formatted(Calendar.current.isDateInToday(reset) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()))")
                    .foregroundStyle(.gray)
                    .monospacedDigit()
            }
            .font(.caption)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.15))
                Rectangle()
                    .fill(Color.claude)
                    .scaleEffect(x: used / 100, anchor: .leading)
            }
            .frame(height: 5)
            .clipShape(Capsule())
        }
    }
}
