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

func normalizedPercent(_ value: Double) -> Double {
    let percent = value <= 1.0 ? value * 100.0 : value
    return min(100.0, max(0.0, percent))
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
        RateWindow(
            usedPercent: normalizedPercent(usedPercent ?? 0),
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
    var subscriptionType: String?
    var rateLimitTier: String?
}

struct ClaudeRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeWindow: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var rateWindow: RateWindow {
        RateWindow(usedPercent: normalizedPercent(utilization), resetsAt: parseAPIDate(resetsAt))
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
    let path = claudeCredentialsPath()
    if FileManager.default.fileExists(atPath: path.path) {
        return try JSONDecoder().decode(ClaudeCredentials.self, from: Data(contentsOf: path))
    }
    let raw = try readKeychainPassword(service: "Claude Code-credentials")
    return try JSONDecoder().decode(ClaudeCredentials.self, from: Data(raw.utf8))
}

func saveClaudeCredentials(_ oauth: ClaudeOAuth) {
    let payload: [String: Any] = [
        "claudeAiOauth": [
            "accessToken": oauth.accessToken ?? "",
            "refreshToken": oauth.refreshToken ?? "",
            "subscriptionType": oauth.subscriptionType ?? "",
            "rateLimitTier": oauth.rateLimitTier ?? ""
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
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

func claudePlan(_ oauth: ClaudeOAuth) -> String? {
    guard let subscription = oauth.subscriptionType, !subscription.isEmpty else { return nil }
    let tier = oauth.rateLimitTier?
        .split(separator: "_")
        .last
        .map(String.init)
    if let tier, !tier.isEmpty {
        return "\(capitalize(subscription)) \(tier)"
    }
    return capitalize(subscription)
}

func fetchClaudeSnapshot() async -> ProviderSnapshot {
    do {
        let credentials = try readClaudeCredentials()
        var oauth = try credentials.claudeAiOauth.unwrap("No Claude OAuth credentials")
        var accessToken = try oauth.accessToken.unwrap("No Claude access token")

        do {
            return try await claudeSnapshot(accessToken: accessToken, oauth: oauth)
        } catch UsageError.http(_, let status) where status == 401 || status == 403 {
            let refreshToken = try oauth.refreshToken.unwrap("No Claude refresh token")
            let refreshed = try await refreshClaudeToken(refreshToken)
            accessToken = try refreshed.accessToken.unwrap("Claude refresh returned no access token")
            oauth.accessToken = accessToken
            oauth.refreshToken = refreshed.refreshToken ?? oauth.refreshToken
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
    let usage = try await requestJSON(
        ClaudeUsageResponse.self,
        request: claudeUsageRequest(accessToken: accessToken),
        provider: "Claude"
    )
    return ProviderSnapshot(
        name: "Claude",
        fiveHour: usage.fiveHour?.rateWindow,
        week: usage.sevenDay?.rateWindow,
        plan: claudePlan(oauth),
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

@MainActor
final class StatusBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var snapshots: [ProviderSnapshot] = []
    private var refreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
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

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if snapshots.isEmpty {
            menu.addItem(NSMenuItem(title: refreshInFlight ? "Loading..." : "No data yet", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        for snapshot in snapshots {
            let title = blackMenuItem(
                [snapshot.name, snapshot.plan].compactMap { $0 }.joined(separator: " · "),
                action: #selector(openProviderUsage(_:))
            )
            title.representedObject = snapshot.usageURL
            menu.addItem(title)
            menu.addItem(usageMenuItem(label: "5h", window: snapshot.fiveHour))
            menu.addItem(usageMenuItem(label: "Week", window: snapshot.week))
            if let updatedAt = snapshot.updatedAt {
                menu.addItem(grayMenuItem("Updated \(dateText(updatedAt))"))
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: refreshInFlight ? "Refreshing..." : "Refresh now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
