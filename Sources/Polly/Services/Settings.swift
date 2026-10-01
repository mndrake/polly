import AppKit
import AVFoundation
import Foundation
import PollyCore
import Security
import Speech

/// UserDefaults keys (used with @AppStorage in views and read directly elsewhere).
enum SettingsKey {
    static let myName = "myName"
    static let claudeModel = "claudeModel"
    static let claudeEffort = "claudeEffort"
    static let transcriptionLocale = "transcriptionLocale"
    static let engine = "transcriptionEngine"
    static let captureMode = "captureMode"
    static let captureMicrophone = "captureMicrophone"
    static let echoSuppression = "echoSuppression"
    static let detectMeetings = "detectMeetings"
    static let notifyOnDetection = "notifyOnDetection"
    static let autoStart = "autoStart"
    static let autoStop = "autoStop"
    static let autoSummarize = "autoSummarize"
    static let customInstructions = "customInstructions"
    static let showCaptionPanel = "showCaptionPanel"
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case meetingApp
    case allSystemAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meetingApp: return "Meeting app only"
        case .allSystemAudio: return "All system audio"
        }
    }
}

/// Typed access to settings with defaults.
enum AppSettings {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.myName: NSFullUserName(),
            SettingsKey.claudeModel: ClaudeModel.default.rawValue,
            SettingsKey.claudeEffort: ClaudeEffort.medium.rawValue,
            SettingsKey.transcriptionLocale: Locale.current.identifier,
            SettingsKey.engine: EnginePreference.automatic.rawValue,
            SettingsKey.captureMode: CaptureMode.meetingApp.rawValue,
            SettingsKey.captureMicrophone: true,
            SettingsKey.echoSuppression: true,
            SettingsKey.detectMeetings: true,
            SettingsKey.notifyOnDetection: true,
            SettingsKey.autoStart: false,
            SettingsKey.autoStop: true,
            SettingsKey.autoSummarize: true,
            SettingsKey.customInstructions: "",
            SettingsKey.showCaptionPanel: true,
        ])
    }

    static var myName: String? {
        let name = defaults.string(forKey: SettingsKey.myName)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }

    static var claudeModel: ClaudeModel {
        ClaudeModel(rawValue: defaults.string(forKey: SettingsKey.claudeModel) ?? "") ?? .default
    }

    static var claudeEffort: ClaudeEffort {
        ClaudeEffort(rawValue: defaults.string(forKey: SettingsKey.claudeEffort) ?? "") ?? .medium
    }

    static var locale: Locale {
        Locale(identifier: defaults.string(forKey: SettingsKey.transcriptionLocale) ?? Locale.current.identifier)
    }

    static var engine: EnginePreference {
        EnginePreference(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .automatic
    }

    static var captureMode: CaptureMode {
        CaptureMode(rawValue: defaults.string(forKey: SettingsKey.captureMode) ?? "") ?? .meetingApp
    }

    static var captureMicrophone: Bool { defaults.bool(forKey: SettingsKey.captureMicrophone) }
    static var echoSuppression: Bool { defaults.bool(forKey: SettingsKey.echoSuppression) }
    static var detectMeetings: Bool { defaults.bool(forKey: SettingsKey.detectMeetings) }
    static var notifyOnDetection: Bool { defaults.bool(forKey: SettingsKey.notifyOnDetection) }
    static var autoStart: Bool { defaults.bool(forKey: SettingsKey.autoStart) }
    static var autoStop: Bool { defaults.bool(forKey: SettingsKey.autoStop) }
    static var autoSummarize: Bool { defaults.bool(forKey: SettingsKey.autoSummarize) }
    static var showCaptionPanel: Bool { defaults.bool(forKey: SettingsKey.showCaptionPanel) }
    static var customInstructions: String? { defaults.string(forKey: SettingsKey.customInstructions) }

    /// Locales offered in Settings (those with on-device recognition support).
    static var transcriptionLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { ($0.localizedString(forIdentifier: $0.identifier) ?? "") < ($1.localizedString(forIdentifier: $1.identifier) ?? "") }
    }
}

/// Stores the Anthropic API key in the login keychain.
enum KeychainStore {
    private static let service = "app.polly.Polly"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        if let stored = read(), !stored.isEmpty { return stored }
        // Convenient for development: `ANTHROPIC_API_KEY=... swift run Polly`.
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var attributes = base
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

enum Permissions {
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
