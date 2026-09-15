import Foundation
import Domain

/// Resolves a Grok account's auth file from probe config.
///
/// `grokHome` follows the CLI's own `GROK_HOME` meaning: the folder that holds
/// `auth.json` (default `~/.grok`). A user who signed in with
/// `GROK_HOME=~/.grok-work grok login` therefore registers `~/.grok-work`.
public enum GrokSessionPath: Sendable {
    public static let grokHomeKey = "grokHome"
    public static let authPathKey = "authPath"
    public static let entryKeyKey = "entryKey"

    /// The `GROK_HOME` folder to read `auth.json` from (`~/.grok` when unset).
    public static func grokHome(for config: ProviderAccountConfig) -> String {
        if let home = config.probeConfig[grokHomeKey], !home.isEmpty {
            return (home as NSString).expandingTildeInPath
        }
        return GrokCredentialLoader.defaultGrokHome
    }

    public static func authFilePath(for config: ProviderAccountConfig) -> String? {
        guard let path = config.probeConfig[authPathKey], !path.isEmpty else {
            return nil
        }
        return (path as NSString).expandingTildeInPath
    }

    public static func entryKey(for config: ProviderAccountConfig) -> String? {
        guard let key = config.probeConfig[entryKeyKey], !key.isEmpty else {
            return nil
        }
        return key
    }

    /// The folder to pass as `GROK_HOME` when (re-)running `grok login` for this
    /// account. Explicit `grokHome` wins; an `authPath`-only account logs in to
    /// the folder that holds that file.
    public static func loginHome(for config: ProviderAccountConfig) -> String {
        if let home = config.probeConfig[grokHomeKey], !home.isEmpty {
            return (home as NSString).expandingTildeInPath
        }
        if let authPath = authFilePath(for: config) {
            return (authPath as NSString).deletingLastPathComponent
        }
        return GrokCredentialLoader.defaultGrokHome
    }

    /// Builds probe config from a path the user typed or picked.
    ///
    /// - A `.json` file is used as-is (`authPath`).
    /// - A folder that already holds `auth.json` is a `GROK_HOME`.
    /// - A folder holding `.grok/auth.json` is a user home; its `.grok` is the `GROK_HOME`.
    /// - Any other folder is assumed to be a `GROK_HOME` that has not been logged in to yet.
    public static func probeConfig(
        fromUserPath path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        let expanded = (path as NSString).expandingTildeInPath
        let lastComponent = (expanded as NSString).lastPathComponent
        if lastComponent == "auth.json" || expanded.lowercased().hasSuffix(".json") {
            return [authPathKey: expanded]
        }
        if fileExists((expanded as NSString).appendingPathComponent("auth.json")) {
            return [grokHomeKey: expanded]
        }
        let nestedHome = (expanded as NSString).appendingPathComponent(".grok")
        if fileExists((nestedHome as NSString).appendingPathComponent("auth.json")) {
            return [grokHomeKey: nestedHome]
        }
        return [grokHomeKey: expanded]
    }
}
