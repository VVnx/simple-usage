import AppKit
import Foundation

struct RateWindow: Sendable {
    let usedPercent: Double
    let resetsAt: Date?
}

struct ProviderSnapshot: Sendable {
    let name: String
    let fiveHour: RateWindow?
    let week: RateWindow?
    let plan: String?
    let usageURL: URL?
    let updatedAt: Date?
    let error: String?
}

enum UsageError: Error, LocalizedError {
    case missingCredentials(String)
    case invalidCredentials(String)
    case http(String, Int)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let message), .invalidCredentials(let message), .process(let message):
            return message
        case .http(let provider, let status):
            if status == 429 {
                return "\(provider) rate limited (HTTP 429)"
            }
            return "\(provider) usage request failed (HTTP \(status))"
        }
    }
}

nonisolated(unsafe) private let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let isoWithoutFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let longFractionFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
    return formatter
}()

func parseAPIDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return isoWithFraction.date(from: raw)
        ?? isoWithoutFraction.date(from: raw)
        ?? longFractionFormatter.date(from: raw)
}

func clampedPercent(_ value: Double) -> Double {
    min(100.0, max(0.0, value))
}

func capitalize(_ raw: String) -> String {
    raw.split(separator: "_")
        .map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

func codexPlanName(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }

    switch raw.lowercased() {
    case "prolite":
        return "Pro 5x"
    case "pro":
        return "Pro"
    case "plus":
        return "Plus"
    case "free":
        return "Free"
    case "team":
        return "Team"
    case "enterprise":
        return "Enterprise"
    default:
        return capitalize(raw)
    }
}

func requestJSON<T: Decodable>(
    _ type: T.Type,
    request: URLRequest,
    provider: String
) async throws -> T {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw UsageError.http(provider, 0)
    }
    guard (200..<300).contains(http.statusCode) else {
        throw UsageError.http(provider, http.statusCode)
    }
    return try JSONDecoder().decode(T.self, from: data)
}

func secretFileAttributes() -> [FileAttributeKey: Any] {
    [.posixPermissions: NSNumber(value: 0o600)]
}

func writeSecretJSON(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: secretFileAttributes())
    } else {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(secretFileAttributes(), ofItemAtPath: url.path)
    }
}

// MARK: - Codex

private let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

struct CodexAuth: Codable {
    var tokens: CodexTokens?
}

struct CodexTokens: Codable {
    var accessToken: String?
    var refreshToken: String?
    var accountID: String?
    var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
        case idToken = "id_token"
    }
}

struct CodexRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    var rateWindow: RateWindow {
        // used_percent is already on a 0...100 scale.
        RateWindow(
            usedPercent: clampedPercent(usedPercent ?? 0),
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

func codexAuthPaths() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var paths: [URL] = []
    if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
        paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
    }
    paths.append(home.appendingPathComponent(".config/codex/auth.json"))
    paths.append(home.appendingPathComponent(".codex/auth.json"))
    return paths
}

func readCodexAuth() throws -> (CodexAuth, URL) {
    for path in codexAuthPaths() where FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        if auth.tokens?.accessToken != nil {
            return (auth, path)
        }
    }
    throw UsageError.missingCredentials("No Codex auth.json found")
}

func saveCodexAuth(_ tokens: CodexTokens, to path: URL) {
    let payload: [String: Any] = [
        "tokens": [
            "access_token": tokens.accessToken ?? "",
            "refresh_token": tokens.refreshToken ?? "",
            "account_id": tokens.accountID ?? "",
            "id_token": tokens.idToken ?? ""
        ],
        "last_refresh": isoWithoutFraction.string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        writeSecretJSON(data, to: path)
    }
}

func codexUsageRequest(accessToken: String, accountID: String?) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.timeoutInterval = 15
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    if let accountID, !accountID.isEmpty {
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    return request
}

func refreshCodexToken(_ refreshToken: String) async throws -> CodexRefreshResponse {
    var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = "grant_type=refresh_token&client_id=\(codexClientID)&refresh_token=\(refreshToken)"
    request.httpBody = body.data(using: .utf8)
    return try await requestJSON(CodexRefreshResponse.self, request: request, provider: "Codex token refresh")
}

func fetchCodexSnapshot() async -> ProviderSnapshot {
    do {
        let (auth, authPath) = try readCodexAuth()
        var tokens = try auth.tokens.unwrap("No Codex tokens")
        var accessToken = try tokens.accessToken.unwrap("No Codex access token")

        do {
            return try await codexSnapshot(accessToken: accessToken, tokens: tokens)
        } catch UsageError.http(_, let status) where status == 401 || status == 403 {
            let refreshToken = try tokens.refreshToken.unwrap("No Codex refresh token")
            let refreshed = try await refreshCodexToken(refreshToken)
            accessToken = try refreshed.accessToken.unwrap("Codex refresh returned no access token")
            tokens.accessToken = accessToken
            tokens.refreshToken = refreshed.refreshToken ?? tokens.refreshToken
            saveCodexAuth(tokens, to: authPath)
            return try await codexSnapshot(accessToken: accessToken, tokens: tokens)
        }
    } catch {
        return ProviderSnapshot(
            name: "Codex",
            fiveHour: nil,
            week: nil,
            plan: nil,
            usageURL: codexUsageURL,
            updatedAt: nil,
            error: error.localizedDescription
        )
    }
}

func codexSnapshot(accessToken: String, tokens: CodexTokens) async throws -> ProviderSnapshot {
    let usage = try await requestJSON(
        CodexUsageResponse.self,
        request: codexUsageRequest(accessToken: accessToken, accountID: tokens.accountID),
        provider: "Codex"
    )
    return ProviderSnapshot(
        name: "Codex",
        fiveHour: usage.rateLimit?.primaryWindow?.rateWindow,
        week: usage.rateLimit?.secondaryWindow?.rateWindow,
        plan: codexPlanName(usage.planType),
        usageURL: codexUsageURL,
        updatedAt: Date(),
        error: nil
    )
}

// MARK: - Claude

private let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let claudeBetaHeader = "oauth-2025-04-20"

struct ClaudeCredentials: Codable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeOAuth: Codable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?
}

struct ClaudeRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    // The token endpoint returns a lifetime in seconds; convert it to the same
    // absolute epoch-milliseconds form Claude Code stores in `expiresAt`.
    var expiresAt: Double? {
        guard let expiresIn else { return nil }
        return Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
    }
}

// Treat a token as expired a minute early to avoid a refresh racing the clock.
func claudeTokenExpired(_ oauth: ClaudeOAuth) -> Bool {
    guard let expiresAt = oauth.expiresAt else { return false }
    return Date().timeIntervalSince1970 * 1000 >= expiresAt - 60_000
}

struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeProfileResponse: Decodable {
    struct Organization: Decodable {
        let organizationType: String?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case organizationType = "organization_type"
            case rateLimitTier = "rate_limit_tier"
        }
    }

    let organization: Organization?
}

struct ClaudeWindow: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var rateWindow: RateWindow {
        // utilization is already a 0...100 percentage (9.0 == 9%); rescaling
        // values <= 1.0 as fractions used to turn 1% into 100%.
        RateWindow(usedPercent: clampedPercent(utilization), resetsAt: parseAPIDate(resetsAt))
    }
}

func readKeychainPassword(service: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw UsageError.missingCredentials("No \(service) Keychain item found")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw UsageError.process("Could not read \(service) Keychain item")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func claudeCredentialsPath() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
}

func readClaudeCredentials() throws -> ClaudeCredentials {
    // Read both stores Claude credentials can live in. On macOS the Keychain is
    // the canonical source Claude Code keeps fresh; the JSON file is a cache this
    // app may have written on a previous refresh. Either can be the stale one, so
    // we pick whichever holds the later-expiring token instead of blindly
    // preferring the file (which would shadow a token Claude Code has rotated).
    var candidates: [ClaudeCredentials] = []
    if let raw = try? readKeychainPassword(service: "Claude Code-credentials"),
       let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: Data(raw.utf8)) {
        candidates.append(creds)
    }
    let path = claudeCredentialsPath()
    if FileManager.default.fileExists(atPath: path.path),
       let data = try? Data(contentsOf: path),
       let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) {
        candidates.append(creds)
    }
    guard let best = candidates.max(by: {
        ($0.claudeAiOauth?.expiresAt ?? 0) < ($1.claudeAiOauth?.expiresAt ?? 0)
    }) else {
        throw UsageError.missingCredentials("No Claude credentials found")
    }
    return best
}

func saveClaudeCredentials(_ oauth: ClaudeOAuth) {
    // Encode the whole struct so every field round-trips — notably `expiresAt` and
    // `scopes`, which the previous hand-built dictionary dropped. Losing `expiresAt`
    // is what left the cached token un-refreshable and stuck behind 429s.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(ClaudeCredentials(claudeAiOauth: oauth)) {
        writeSecretJSON(data, to: claudeCredentialsPath())
    }
}

func claudeUsageRequest(accessToken: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.timeoutInterval = 15
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(claudeBetaHeader, forHTTPHeaderField: "anthropic-beta")
    return request
}

func claudeProfileRequest(accessToken: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
    request.timeoutInterval = 15
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(claudeBetaHeader, forHTTPHeaderField: "anthropic-beta")
    return request
}

func refreshClaudeToken(_ refreshToken: String) async throws -> ClaudeRefreshResponse {
    var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": claudeClientID,
        "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await requestJSON(ClaudeRefreshResponse.self, request: request, provider: "Claude token refresh")
}

// The credential stores keep whatever subscription metadata existed at login and
// are not rewritten when the plan changes, so the live profile endpoint is the
// only reliable source; cached metadata is just the offline fallback.
func claudePlan(profile: ClaudeProfileResponse?, oauth: ClaudeOAuth) -> String? {
    if let organization = profile?.organization,
       let plan = claudePlanName(subscription: organization.organizationType, tier: organization.rateLimitTier) {
        return plan
    }
    return claudePlanName(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier)
}

func claudePlanName(subscription: String?, tier: String?) -> String? {
    guard var subscription = subscription?.trimmingCharacters(in: .whitespacesAndNewlines),
          !subscription.isEmpty else { return nil }
    // Profile reports "claude_max" where the credentials store just "max".
    if subscription.lowercased().hasPrefix("claude_") {
        subscription = String(subscription.dropFirst("claude_".count))
    }
    let tierSuffix = tier?
        .split(separator: "_")
        .last
        .map(String.init)
    if let tierSuffix, !tierSuffix.isEmpty {
        return "\(capitalize(subscription)) \(tierSuffix)"
    }
    return capitalize(subscription)
}

func fetchClaudeSnapshot() async -> ProviderSnapshot {
    do {
        let credentials = try readClaudeCredentials()
        var oauth = try credentials.claudeAiOauth.unwrap("No Claude OAuth credentials")
        var accessToken = try oauth.accessToken.unwrap("No Claude access token")

        // Refresh proactively when the token is already expired: the usage endpoint
        // answers an expired token with 429, not 401, so the reactive path below
        // would never fire and the app would stay stuck rate-limited.
        if claudeTokenExpired(oauth), let refreshToken = oauth.refreshToken,
           let refreshed = try? await refreshClaudeToken(refreshToken),
           let newAccess = refreshed.accessToken {
            accessToken = newAccess
            oauth.accessToken = newAccess
            oauth.refreshToken = refreshed.refreshToken ?? oauth.refreshToken
            oauth.expiresAt = refreshed.expiresAt ?? oauth.expiresAt
            saveClaudeCredentials(oauth)
        }

        do {
            return try await claudeSnapshot(accessToken: accessToken, oauth: oauth)
        } catch UsageError.http(_, let status) where status == 401 || status == 403 {
            let refreshToken = try oauth.refreshToken.unwrap("No Claude refresh token")
            let refreshed = try await refreshClaudeToken(refreshToken)
            accessToken = try refreshed.accessToken.unwrap("Claude refresh returned no access token")
            oauth.accessToken = accessToken
            oauth.refreshToken = refreshed.refreshToken ?? oauth.refreshToken
            oauth.expiresAt = refreshed.expiresAt ?? oauth.expiresAt
            saveClaudeCredentials(oauth)
            return try await claudeSnapshot(accessToken: accessToken, oauth: oauth)
        }
    } catch {
        return ProviderSnapshot(
            name: "Claude",
            fiveHour: nil,
            week: nil,
            plan: nil,
            usageURL: claudeUsageURL,
            updatedAt: nil,
            error: error.localizedDescription
        )
    }
}

func claudeSnapshot(accessToken: String, oauth: ClaudeOAuth) async throws -> ProviderSnapshot {
    async let profileFetch = try? requestJSON(
        ClaudeProfileResponse.self,
        request: claudeProfileRequest(accessToken: accessToken),
        provider: "Claude profile"
    )
    let usage = try await requestJSON(
        ClaudeUsageResponse.self,
        request: claudeUsageRequest(accessToken: accessToken),
        provider: "Claude"
    )
    let profile = await profileFetch
    return ProviderSnapshot(
        name: "Claude",
        fiveHour: usage.fiveHour?.rateWindow,
        week: usage.sevenDay?.rateWindow,
        plan: claudePlan(profile: profile, oauth: oauth),
        usageURL: claudeUsageURL,
        updatedAt: Date(),
        error: nil
    )
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw UsageError.invalidCredentials(message) }
        return self
    }
}

// MARK: - UI

private let codexUsageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/usage")!
private let claudeUsageURL = URL(string: "https://claude.ai/new#settings/usage")!

func collectUsage() async -> [ProviderSnapshot] {
    async let codex = fetchCodexSnapshot()
    async let claude = fetchClaudeSnapshot()
    return await [codex, claude]
}

func percentText(_ window: RateWindow?) -> String {
    guard let window else { return "n/a" }
    return "\(String(format: "%.0f", window.usedPercent))%"
}

func statusIcon() -> NSImage {
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("usage-icon.png"),
       let image = NSImage(contentsOf: resourceURL) {
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    let image = NSImage(size: NSSize(width: 18, height: 18))
    image.lockFocus()
    NSColor.labelColor.setStroke()
    NSColor.labelColor.setFill()
    for (index, height) in [5.0, 8.0, 11.0].enumerated() {
        let rect = NSRect(x: 5.0 + Double(index) * 3.8, y: 4, width: 2.4, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 1.0, yRadius: 1.0).fill()
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
}

func usageMenuItem(label: String, window: RateWindow?) -> NSMenuItem {
    let percent = percentText(window)
    let resetText = "reset \(dateText(window?.resetsAt)) (\(countdownText(window?.resetsAt)))"
    let title = "\(label)  \(percent)  \(resetText)"
    let attributed = NSMutableAttributedString(
        string: title,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.black
        ]
    )
    if let range = title.range(of: resetText) {
        attributed.addAttributes(
            [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.disabledControlTextColor
            ],
            range: NSRange(range, in: title)
        )
    }
    if let range = title.range(of: percent) {
        attributed.addAttributes(
            [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.black
            ],
            range: NSRange(range, in: title)
        )
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.attributedTitle = attributed
    item.isEnabled = true
    return item
}

func blackMenuItem(_ title: String, action: Selector? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.black
        ]
    )
    item.isEnabled = true
    return item
}

func grayMenuItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.disabledControlTextColor
        ]
    )
    item.isEnabled = true
    return item
}

func dateText(_ date: Date?) -> String {
    guard let date else { return "n/a" }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE HH:mm"
    return formatter.string(from: date)
}

func countdownText(_ date: Date?) -> String {
    guard let date else { return "n/a" }
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    }
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

// A menu row backed by a custom view: clicking it runs `onClick` without
// dismissing the menu, which a regular NSMenuItem action cannot do.
@MainActor
private final class MenuActionRowView: NSView {
    private let highlight: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .selection
        view.state = .active
        view.isEmphasized = true
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.menuFont(ofSize: 0)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    // The view replaces the whole row, so the key equivalent AppKit would
    // normally draw has to be rendered by hand.
    private let shortcutLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.menuFont(ofSize: 0)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    var onClick: (() -> Void)?
    private var isHighlighted = false

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var shortcutHint: String {
        get { shortcutLabel.stringValue }
        set { shortcutLabel.stringValue = newValue }
    }

    var isActionEnabled = true {
        didSet {
            if !isActionEnabled {
                setHighlighted(false)
            }
            applyLabelColor()
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        addSubview(highlight)
        addSubview(label)
        addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyLabelColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        if isActionEnabled {
            setHighlighted(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isActionEnabled else { return }
        onClick?()
    }

    private func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        highlight.isHidden = !highlighted
        applyLabelColor()
    }

    private func applyLabelColor() {
        if !isActionEnabled {
            label.textColor = .disabledControlTextColor
            shortcutLabel.textColor = .disabledControlTextColor
        } else if isHighlighted {
            label.textColor = .selectedMenuItemTextColor
            shortcutLabel.textColor = .selectedMenuItemTextColor
        } else {
            label.textColor = .labelColor
            shortcutLabel.textColor = .secondaryLabelColor
        }
    }
}

@MainActor
final class StatusBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let refreshView = MenuActionRowView()
    private lazy var refreshItem: NSMenuItem = {
        let item = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        item.target = self
        refreshView.shortcutHint = "⌘R"
        item.view = refreshView
        return item
    }()
    private var timer: Timer?
    private var snapshots: [ProviderSnapshot] = []
    private var refreshInFlight = false
    private var lastRefreshStarted: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshView.onClick = { [weak self] in self?.refresh() }
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Timers do not fire while the Mac sleeps, so data can be hours old when
        // the menu opens; rebuild regardless so countdowns reflect "now".
        if let lastRefreshStarted, Date().timeIntervalSince(lastRefreshStarted) < 60 {
            rebuildMenu()
        } else {
            refresh()
        }
    }

    @objc private func systemDidWake() {
        // Give the network a moment to come back before fetching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        lastRefreshStarted = Date()
        rebuildMenu()
        Task {
            let fetchedSnapshots = await collectUsage()
            self.snapshots = self.mergingWithPreviousSuccessfulData(fetchedSnapshots)
            self.refreshInFlight = false
            self.rebuildMenu()
        }
    }

    private func mergingWithPreviousSuccessfulData(_ fetchedSnapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let previousByName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0) })
        return fetchedSnapshots.map { fetched in
            guard fetched.error != nil else {
                return fetched
            }
            return previousByName[fetched.name] ?? ProviderSnapshot(
                name: fetched.name,
                fiveHour: fetched.fiveHour,
                week: fetched.week,
                plan: fetched.plan,
                usageURL: fetched.usageURL,
                updatedAt: nil,
                error: nil
            )
        }
    }

    // Mutates the persistent menu in place: replacing `statusItem.menu` would
    // leave an already-open menu showing stale rows, while in-place updates are
    // redrawn live, so a user keeping the menu open sees the refresh land.
    private func rebuildMenu() {
        menu.removeAllItems()
        if snapshots.isEmpty {
            menu.addItem(NSMenuItem(title: refreshInFlight ? "Loading..." : "No data yet", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        for snapshot in snapshots {
            let title = blackMenuItem(
                [snapshot.name, snapshot.plan].compactMap { $0 }.joined(separator: " · "),
                action: #selector(openProviderUsage(_:))
            )
            title.target = self
            title.representedObject = snapshot.usageURL
            menu.addItem(title)
            menu.addItem(usageMenuItem(label: "5h", window: snapshot.fiveHour))
            menu.addItem(usageMenuItem(label: "Week", window: snapshot.week))
            if let updatedAt = snapshot.updatedAt {
                menu.addItem(grayMenuItem("Updated \(dateText(updatedAt))"))
            }
            menu.addItem(.separator())
        }

        refreshView.title = refreshInFlight ? "Refreshing..." : "Refresh now"
        refreshView.isActionEnabled = !refreshInFlight
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openProviderUsage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = StatusBarApp()
app.delegate = delegate
app.run()
