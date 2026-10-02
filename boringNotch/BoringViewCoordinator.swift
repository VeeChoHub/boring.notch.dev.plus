//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

// Stato di una sessione Claude Code, inviato da claude-hook.js. rawValue = priorità nel notch.
enum ClaudeState: Int, CaseIterable {
    case idle
    case working
    case done // ha appena finito (hook Stop): "<nome> Completata" nel notch chiuso per 5 s, poi torna idle
    case question
    case permission
}

// Suoni di fine sessione: data set in Assets.xcassets/Claude Sounds, nome = file originale
enum ClaudeSound {
    static let names = ["Confirm 1", "Confirm 2", "Cyberpunk", "GTA Online", "GTA V Franklin", "Minecraft Raid", "One Piece 1"].sorted()
    private static var current: NSSound? // riferimento forte finché suona; un nuovo suono interrompe il precedente
    private static var next = 0 // ponytail: posizione nella sequenza solo in memoria, riparte dal primo al riavvio

    // Custom: ordine salvato; i suoni non ancora ordinati (es. aggiunti dopo) vanno in coda in ordine alfabetico
    static func ordered(_ saved: [String], _ sort: ClaudeSoundSort = .custom) -> [String] {
        switch sort {
        case .az: return names
        case .za: return names.reversed()
        case .custom:
            let saved = saved.filter(names.contains)
            return saved + names.filter { !saved.contains($0) }
        }
    }

    static func playNext() {
        let sounds = ordered(Defaults[.claudeSoundOrder], Defaults[.claudeSoundSort]).filter(Defaults[.claudeSounds].contains)
        guard !sounds.isEmpty else { return }
        play(Defaults[.claudeSoundsRandom] ? sounds.randomElement()! : sounds[next % sounds.count])
        next += 1
    }

    static func play(_ name: String) {
        current?.stop()
        current = NSDataAsset(name: name).flatMap { NSSound(data: $0.data) }
        current?.play()
    }
}

struct ClaudeSession {
    var state: ClaudeState
    var cwd: String
    var since: Date = .now
    var context: Double? // finestra di contesto usata, 0-100 (dalla statusline)
    var model: String? // "Opus 5.5" (statusline)
    var tokens: String? // contesto in token usati/totali, "85k/1M" (statusline)
    var task: String? // token e costo dell'ultima task, "24.7k tok | $0.36" (hook Stop)
    // Riga della card di fine sessione: "Opus 5.5 · 85k/1M | 24.7k tok | $0.36"
    var details: String {
        [[model, tokens].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), task ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " | ")
    }
    var agents: [String: Bool] = [:] // subagent dell'ultimo gruppo lanciato: agent_id → finito
    var agentsRunning: Bool { agents.values.contains(false) }
}

// rate_limits della statusline di Claude Code (used_percentage 0-100, resets_at epoch in secondi)
struct ClaudeLimit: Decodable {
    let usedPercentage: Double
    let resetsAt: TimeInterval
}

extension ClaudeLimit {
    // Dato persistito con finestra già scaduta: il limite è stato azzerato
    var used: Double { Date(timeIntervalSince1970: resetsAt) < .now ? 0 : min(usedPercentage, 100) }
}

struct ClaudeLimits: Decodable {
    let fiveHour: ClaudeLimit?
    let sevenDay: ClaudeLimit?
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    // ponytail: una sessione uccisa senza SessionEnd resta in lista fino al riavvio dell'app; aggiungere un timeout se succede
    @Published var claudeSessions: [String: ClaudeSession] = [:]
    // Stato più urgente tra le sessioni attive: nil se nessuna lavora (le idle non compaiono nel notch chiuso)
    var claudeState: ClaudeState? {
        claudeSessions.values.map(\.state).filter { $0 != .idle }.max { $0.rawValue < $1.rawValue }
    }
    // Ultima sessione appena completata (card "Completata" nel notch chiuso)
    var claudeCompleted: ClaudeSession? {
        claudeSessions.values.filter { $0.state == .done }.max { $0.since < $1.since }
    }

    // JSON grezzo dell'ultimo rate_limits ricevuto: persistito, così la pagina non è vuota dopo un riavvio
    @AppStorage("claudeLimits") var claudeLimitsJSON: String = ""
    var claudeLimits: ClaudeLimits? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ClaudeLimits.self, from: Data(claudeLimitsJSON.utf8))
    }

    private init() {
        // Claude Code: "boringnotch.claude.<stato>" con object = session_id; "ended" (nil) rimuove la sessione
        for state in ClaudeState.allCases.map(Optional.some) + [nil] {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("boringnotch.claude.\(state.map { "\($0)" } ?? "ended")"),
                object: nil, queue: .main) { [weak self] notification in
                    guard let id = notification.object as? String else { return }
                    let cwd = notification.userInfo?["cwd"] as? String ?? ""
                    // Interruzione con Esc (dalla statusline): vale solo se più recente dell'ultimo cambio di stato
                    let at = (notification.userInfo?["at"] as? Double).map(Date.init(timeIntervalSince1970:))
                    let task = notification.userInfo?["task"] as? String
                    Task { @MainActor in
                        guard let self else { return }
                        if let at, let since = self.claudeSessions[id]?.since, at < since { return }
                        withAnimation(.smooth) {
                            guard var new = state else { self.claudeSessions[id] = nil; return }
                            let old = self.claudeSessions[id]
                            // idle_prompt arriva anche mentre aspetta i subagent in background: resta al lavoro.
                            // ponytail: anche Esc che uccide i subagent (niente SubagentStop) lascia "al lavoro" fino al prossimo Stop
                            if new == .idle, old?.agentsRunning == true { new = .working }
                            if old?.state != new {
                                var session = old ?? ClaudeSession(state: new, cwd: cwd)
                                session.state = new
                                session.cwd = cwd
                                session.since = .now
                                // done arriva solo senza subagent in background (claude-hook.js): azzera anche quelli uccisi
                                if new == .done { session.agents = [:]; session.task = task }
                                self.claudeSessions[id] = session
                                if new == .done { ClaudeSound.playNext() }
                            }
                        }
                        guard state == .done, let since = self.claudeSessions[id]?.since else { return }
                        try? await Task.sleep(for: .seconds(5))
                        // Torna idle solo se nel frattempo non è cambiato nulla (es. un nuovo prompt)
                        if self.claudeSessions[id]?.state == .done, self.claudeSessions[id]?.since == since {
                            withAnimation(.smooth) { self.claudeSessions[id]?.state = .idle }
                        }
                    }
            }
        }
        // Subagent: "boringnotch.claude.agent" con userInfo { agent: agent_id, done: SubagentStop }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("boringnotch.claude.agent"),
            object: nil, queue: .main) { [weak self] notification in
                guard let id = notification.object as? String,
                      let agent = notification.userInfo?["agent"] as? String else { return }
                let done = notification.userInfo?["done"] as? Bool ?? false
                Task { @MainActor in
                    guard let self, var session = self.claudeSessions[id] else { return }
                    if !done {
                        // Nessuno dei precedenti lavora più: nuovo gruppo, il conteggio riparte
                        if !session.agentsRunning { session.agents = [:] }
                        session.agents[agent] = false
                    } else if session.agents[agent] != nil {
                        session.agents[agent] = true
                    }
                    self.claudeSessions[id] = session
                }
        }
        // Finestra di contesto: "boringnotch.claude.context" con userInfo { pct, model, tokens } (statusline, solo sessioni già note)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("boringnotch.claude.context"),
            object: nil, queue: .main) { [weak self] notification in
                guard let id = notification.object as? String,
                      let pct = notification.userInfo?["pct"] as? Double else { return }
                let model = notification.userInfo?["model"] as? String
                let tokens = notification.userInfo?["tokens"] as? String
                Task { @MainActor in
                    guard let self, var session = self.claudeSessions[id] else { return }
                    let old = session
                    session.context = pct
                    session.model = model
                    session.tokens = tokens
                    if (old.context, old.model, old.tokens) != (pct, model, tokens) { self.claudeSessions[id] = session }
                }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("boringnotch.claude.limits"),
            object: nil, queue: .main) { [weak self] notification in
                guard let json = notification.userInfo?["json"] as? String else { return }
                Task { @MainActor in
                    if self?.claudeLimitsJSON != json { self?.claudeLimitsJSON = json }
                }
        }


        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
