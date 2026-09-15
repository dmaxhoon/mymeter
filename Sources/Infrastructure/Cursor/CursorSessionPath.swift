import Foundation
import Domain

/// Resolves a Cursor account's `state.vscdb` path from probe config.
public enum CursorSessionPath: Sendable {
    public static let dbPathKey = "dbPath"
    public static let userDataDirKey = "userDataDir"

    public static func databasePath(for config: ProviderAccountConfig) -> String {
        if let dbPath = config.probeConfig[dbPathKey], !dbPath.isEmpty {
            return (dbPath as NSString).expandingTildeInPath
        }
        if let userDataDir = config.probeConfig[userDataDirKey], !userDataDir.isEmpty {
            let expanded = (userDataDir as NSString).expandingTildeInPath
            return (expanded as NSString).appendingPathComponent("User/globalStorage/state.vscdb")
        }
        return CursorUsageProbe.defaultDatabasePath
    }

    public static func probeConfig(fromUserPath path: String) -> [String: String] {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasSuffix(".vscdb") {
            return [dbPathKey: expanded]
        }
        return [userDataDirKey: expanded]
    }
}
