import Foundation

/// Helpers for path-backed multi-account providers (Cursor, Grok).
///
/// Stored settings may omit the default local session. The UI always needs
/// at least that implicit account, then any extra sessions the user added.
public enum SessionAccounts: Sendable {
    public static func resolved(
        stored: [ProviderAccountConfig],
        defaultLabel: String = "Default"
    ) -> [ProviderAccountConfig] {
        if stored.contains(where: { $0.accountId == ProviderAccount.defaultAccountId }) {
            return stored
        }
        let implicitDefault = ProviderAccountConfig(
            accountId: ProviderAccount.defaultAccountId,
            label: defaultLabel
        )
        return [implicitDefault] + stored
    }

    public static func uniqueAccountId(from label: String, existing: [String]) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = slugify(trimmed.isEmpty ? "account" : trimmed)
        if !existing.contains(slug) {
            return slug
        }
        var suffix = 2
        while existing.contains("\(slug)-\(suffix)") {
            suffix += 1
        }
        return "\(slug)-\(suffix)"
    }

    private static func slugify(_ text: String) -> String {
        let mapped = text.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "account" : collapsed
    }
}
