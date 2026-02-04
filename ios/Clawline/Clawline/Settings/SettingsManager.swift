//
//  SettingsManager.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import Observation

@Observable
@MainActor
final class SettingsManager {
    var effectConfig: BackgroundEffectConfiguration {
        didSet { save() }
    }

    enum AppearanceMode: String, Codable {
        case dark
        case light
    }

    var appearanceMode: AppearanceMode {
        didSet { saveAppearanceMode() }
    }

    var isSettingsPresented: Bool = false

    private static let effectConfigKey = "backgroundEffectConfiguration"
    private static let appearanceModeKey = "appearanceMode"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.effectConfigKey),
           let config = try? JSONDecoder().decode(BackgroundEffectConfiguration.self, from: data) {
            self.effectConfig = config
        } else {
            self.effectConfig = .default
        }

        if let raw = UserDefaults.standard.string(forKey: Self.appearanceModeKey),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .dark
        }

    }

    private func save() {
        if let data = try? JSONEncoder().encode(effectConfig) {
            UserDefaults.standard.set(data, forKey: Self.effectConfigKey)
        }
    }

    private func saveAppearanceMode() {
        UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
    }

    func resetToDefaults() {
        effectConfig = .default
        appearanceMode = .dark
    }

    func toggleSettings() {
        isSettingsPresented.toggle()
    }

    var preferredColorScheme: ColorScheme {
        appearanceMode == .dark ? .dark : .light
    }

    func toggleAppearanceMode() {
        appearanceMode = appearanceMode == .dark ? .light : .dark
    }
}

// MARK: - Environment Key

private struct SettingsManagerKey: EnvironmentKey {
    static let defaultValue: SettingsManager = SettingsManager()
}

extension EnvironmentValues {
    var settingsManager: SettingsManager {
        get { self[SettingsManagerKey.self] }
        set { self[SettingsManagerKey.self] = newValue }
    }
}
