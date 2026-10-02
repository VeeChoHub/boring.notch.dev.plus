//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {

    // MARK: - Claude Code (chat del notch: l'app è in sandbox e non può lanciare claude)

    /// Onboarding nelle impostazioni: `claude-hook.js install` (Contents/Resources dell'app, copiato da install.sh)
    /// scrive hook e statusline in ~/.claude/settings.json. Reply: il settings.json punta a questa copia dello script.
    @objc func claudeHook(_ install: Bool, with reply: @escaping (Bool) -> Void) {
        // Questo bundle è Contents/XPCServices/BoringNotchXPCHelper.xpc
        let hook = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/claude-hook.js").path
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        if install {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", hook, "install", hook, settings.path]
            try? process.run()
            process.waitUntilExit()
        }
        reply((try? String(contentsOf: settings, encoding: .utf8))?.contains(hook) ?? false)
    }

    /// Un messaggio = un processo `claude -p` nella home; `--resume` prosegue la sessione.
    /// Mentre Claude lavora, testo e tool usati arrivano all'app come distributed notification
    /// "boringnotch.claude.chat" (userInfo: role, text). La reply restituisce il session_id (nil se non è partito).
    @objc func runClaude(_ prompt: String, sessionId: String?, with reply: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Shell di login: stesso PATH del terminale (claude sta in ~/.local/bin).
        // ${2:+--resume} ${2:+"$2"} separati: zsh non divide le parole, "--resume id" sarebbe un argomento unico
        process.arguments = [
            "-lc", "exec claude -p \"$1\" --output-format stream-json --verbose ${2:+--resume} ${2:+\"$2\"}",
            "claude", prompt, sessionId ?? "",
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { reply(nil); return }

        func post(_ role: String, _ text: String) {
            DistributedNotificationCenter.default().postNotificationName(
                .init("boringnotch.claude.chat"), object: nil,
                userInfo: ["role": role, "text": text], deliverImmediately: true)
        }

        Task.detached {
            var session: String?
            // do/catch: se la lettura fallisce la reply deve partire comunque, o l'app resta in attesa
            do { for try await line in output.fileHandleForReading.bytes.lines {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                session = event["session_id"] as? String ?? session
                switch event["type"] as? String {
                case "assistant":
                    // Solo testo e nome del tool: i tool_result (eventi "user") possono essere enormi e non servono
                    for block in (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                        if block["type"] as? String == "text", let text = block["text"] as? String {
                            post("assistant", text)
                        } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                            let input = block["input"] as? [String: Any] ?? [:]
                            let detail = ["command", "file_path", "pattern", "url", "query", "description"]
                                .lazy.compactMap { input[$0] as? String }.first ?? ""
                            post("tool", "\(name) · \(detail.prefix(120))")
                        }
                    }
                case "result" where event["is_error"] as? Bool == true:
                    post("error", event["result"] as? String ?? "Errore di Claude Code")
                default:
                    break
                }
            } } catch {}
            process.waitUntilExit()
            reply(session)
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
