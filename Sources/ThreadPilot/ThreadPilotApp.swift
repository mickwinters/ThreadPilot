import AppKit
import AVFoundation
import Contacts
import Speech
import SQLite3
import SwiftUI

@main
struct ThreadPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            TriageDashboardView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ThreadPilot") {
                    AboutPanel.show()
                }
            }

            CommandGroup(replacing: .help) {
                Button("ThreadPilot Help") {
                    HelpWindow.show()
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        Settings {
            ResponseSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let icon = AppIconLoader.icon {
            NSApp.applicationIconImage = icon
        }

        removeStandardMenus()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func removeStandardMenus() {
        let hiddenMenuTitles = Set(["File", "Edit", "View", "Window"])

        for item in NSApp.mainMenu?.items ?? [] where hiddenMenuTitles.contains(item.title) {
            NSApp.mainMenu?.removeItem(item)
        }
    }
}

enum AppIconLoader {
    static var icon: NSImage? {
        if let assetIcon = NSImage(named: "AppIcon") {
            return assetIcon
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return NSImage(named: NSImage.applicationIconName)
        }

        return NSImage(contentsOf: iconURL)
    }
}

enum AboutPanel {
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ThreadPilot",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        ]

        if let icon = AppIconLoader.icon {
            options[.applicationIcon] = icon
        }

        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

enum HelpWindow {
    private static var window: NSWindow?

    @MainActor
    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let helpWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        helpWindow.title = "ThreadPilot Help"
        helpWindow.center()
        helpWindow.isReleasedWhenClosed = false
        helpWindow.contentViewController = NSHostingController(
            rootView: HelpCenterView {
                helpWindow.close()
            }
        )
        helpWindow.delegate = HelpWindowDelegate.shared
        window = helpWindow
        helpWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    fileprivate static func didClose() {
        window = nil
    }
}

final class HelpWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = HelpWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            HelpWindow.didClose()
        }
    }
}

final class ThreadSummarySpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: cleanText)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else {
            isSpeaking = false
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}

struct MessageThread: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case actionRequired = "Action Required"
        case opportunities = "Opportunities"
        case noise = "Noise"

        var id: String { rawValue }
    }

    let id: String
    let sender: String
    let participants: [String]
    let replyHandles: [String]
    let replyService: String
    let unreadCount: Int
    let preview: String
    let summary: String
    let suggestedAction: String
    let category: Category
    let confidence: Double
    let messages: [ThreadMessage]
}

struct ThreadMessage: Identifiable {
    let id = UUID()
    let sender: String
    let text: String
    let date: Date?
    let service: String
}

enum MessagesLoadState: Equatable {
    case idle
    case loading
    case loaded(Int)
    case failed(String)
}

struct PermissionPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum ResponseSettings {
    static let approveKey = "response.approve"
    static let rejectKey = "response.reject"
    static let discussKey = "response.discuss"
    static let completedKey = "response.completed"
    static let workingKey = "response.working"
    static let notStartedKey = "response.notStarted"
    static let yesKey = "response.yes"
    static let noKey = "response.no"
    static let interestedKey = "response.interested"
    static let notInterestedKey = "response.notInterested"

    static let approveDefault = "Approved"
    static let rejectDefault = "Rejected"
    static let discussDefault = "Will arrange for a meeting, we need to discuss"
    static let completedDefault = "Work completed"
    static let workingDefault = "In Progess"
    static let notStartedDefault = "Work to be scheduled"
    static let yesDefault = "Yes"
    static let noDefault = "No"
    static let interestedDefault = "Lets schedule a meeting"
    static let notInterestedDefault = "Not interested at this time"
}

@MainActor
final class ThreadTriageStore: ObservableObject {
    @Published var threads: [MessageThread] = MessageThread.samples
    @Published var loadState: MessagesLoadState = .idle
    @Published var permissionPrompt: PermissionPrompt?

    func loadLocalMessages() {
        loadState = .loading

        Task {
            do {
                let loadedThreads = try await Task.detached {
                    try MessagesDatabaseLoader().loadThreadsForTriage()
                }.value

                threads = loadedThreads.isEmpty ? [] : loadedThreads
                loadState = .loaded(loadedThreads.count)
            } catch {
                loadState = .failed(error.localizedDescription)

                if let databaseError = error as? MessagesDatabaseError, case .cannotOpen = databaseError {
                    permissionPrompt = PermissionPrompt(
                        title: "Full Disk Access Needed",
                        message: "ThreadPilot needs permission to read your local Messages database. Open System Settings, add ThreadPilot to Full Disk Access, then quit and relaunch the app."
                    )
                }
            }
        }
    }

    func markThreadHandled(_ threadID: MessageThread.ID) {
        threads.removeAll { $0.id == threadID }
        loadState = .loaded(threads.count)
    }
}

enum MessagesDatabaseError: LocalizedError {
    case databaseMissing(String)
    case cannotOpen(String)
    case queryFailed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "Could not find Messages database at \(path). Make sure Messages is configured on this Mac."
        case .cannotOpen(let path):
            return "macOS blocked access to \(path). Grant Full Disk Access to ThreadPilot if launching directly, or Xcode if using Run, then quit and relaunch."
        case .queryFailed(let message):
            return "Could not read Messages data: \(message)"
        case .updateFailed(let message):
            return "Could not mark the thread as read: \(message)"
        }
    }
}

struct MessagesDatabaseLoader {
    private let databasePath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    func loadThreadsForTriage() throws -> [MessageThread] {
        let unreadThreads = try loadThreads(unreadOnly: true)
        return unreadThreads.isEmpty ? try loadThreads(unreadOnly: false) : unreadThreads
    }

    func markThreadRead(threadID: String) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw MessagesDatabaseError.databaseMissing(databasePath)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            throw MessagesDatabaseError.cannotOpen(databasePath)
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 1_000)

        let sql = """
        UPDATE message
        SET is_read = 1
        WHERE IFNULL(is_from_me, 0) = 0
          AND IFNULL(is_read, 0) = 0
          AND ROWID IN (
            SELECT m.ROWID
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE c.guid = ?
          )
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessagesDatabaseError.updateFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MessagesDatabaseError.updateFailed(lastError(database))
        }
    }

    private func loadThreads(unreadOnly: Bool) throws -> [MessageThread] {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw MessagesDatabaseError.databaseMissing(databasePath)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw MessagesDatabaseError.cannotOpen(databasePath)
        }
        defer { sqlite3_close(database) }

        let contactNames = ContactNameResolver()
        let unreadFilter = unreadOnly ? "AND IFNULL(m.is_read, 0) = 0" : ""
        let limit = unreadOnly ? 500 : 250
        let sql = """
        SELECT
            COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), NULLIF(h.id, ''), 'Unknown Thread') AS thread_name,
            COALESCE(m.text, '') AS body,
            m.attributedBody AS attributed_body,
            COALESCE(m.service, '') AS service,
            m.date AS message_date,
            c.guid AS chat_guid,
            COALESCE(c.chat_identifier, '') AS chat_identifier,
            COALESCE(h.id, '') AS sender_id,
            COALESCE((
                SELECT GROUP_CONCAT(DISTINCT handle.id)
                FROM chat_handle_join chj
                JOIN handle ON handle.ROWID = chj.handle_id
                WHERE chj.chat_id = c.ROWID
            ), '') AS participant_names,
            '' AS attachment_names
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE IFNULL(m.is_from_me, 0) = 0
          \(unreadFilter)
        ORDER BY m.date DESC
        LIMIT \(limit)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessagesDatabaseError.queryFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        var grouped: [String: (name: String, participants: [String], replyHandles: [String], replyService: String, messages: [ThreadMessage])] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let name = columnText(statement, 0)
            let body = columnText(statement, 1)
            let richBody = columnData(statement, 2).flatMap(decodeAttributedBody)
            let service = columnText(statement, 3)
            let rawDate = sqlite3_column_int64(statement, 4)
            let chatGUID = columnText(statement, 5)
            let chatIdentifier = columnText(statement, 6)
            let senderID = columnText(statement, 7)
            let rawParticipantHandles = parseParticipants(columnText(statement, 8), fallback: "")
            let rawReplyHandles = mergeParticipants(rawParticipantHandles, [senderID, chatIdentifier])
                .filter(isUsableReplyHandle)
            let displayHandles = rawReplyHandles.isEmpty ? parseParticipants(columnText(statement, 8), fallback: name) : rawReplyHandles
            let participants = displayHandles
                .map(contactNames.displayName(for:))
            let threadID = chatGUID.isEmpty ? name : chatGUID
            guard let readableBody = readableMessageText(text: body, richBody: richBody) else {
                continue
            }

            let sender = senderID.isEmpty ? name : contactNames.displayName(for: senderID)
            let message = ThreadMessage(sender: sender, text: readableBody, date: appleMessageDate(rawDate), service: service)

            var entry = grouped[threadID] ?? (name: name, participants: participants, replyHandles: rawReplyHandles, replyService: service, messages: [])
            entry.participants = mergeParticipants(entry.participants, participants)
            entry.replyHandles = mergeParticipants(entry.replyHandles, rawReplyHandles)
            if entry.replyService.isEmpty {
                entry.replyService = service
            }
            entry.messages.append(message)
            grouped[threadID] = entry
        }

        return grouped
            .filter { !$0.value.messages.isEmpty }
            .map { threadID, entry in
            ThreadClassifier.classify(
                id: threadID,
                name: entry.name,
                participants: entry.participants,
                replyHandles: entry.replyHandles,
                replyService: entry.replyService,
                messages: entry.messages
            )
        }
        .sorted { lhs, rhs in
            if lhs.category.rawValue != rhs.category.rawValue {
                return categoryRank(lhs.category) < categoryRank(rhs.category)
            }

            return lhs.unreadCount > rhs.unreadCount
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            return ""
        }

        return String(cString: cString)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let blob = sqlite3_column_blob(statement, index) else {
            return nil
        }

        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else { return nil }

        return Data(bytes: blob, count: byteCount)
    }

    private func decodeAttributedBody(_ data: Data) -> String? {
        if let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return validatedMessageText(attributed.string)
        }

        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
            if let attributed = object as? NSAttributedString {
                return validatedMessageText(attributed.string)
            }

            if let text = object as? String {
                return validatedMessageText(text)
            }
        }

        if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return extractText(from: propertyList)
        }

        return nil
    }

    private func extractText(from propertyList: Any) -> String? {
        if let text = propertyList as? String {
            return validatedMessageText(text)
        }

        if let array = propertyList as? [Any] {
            return array.compactMap(extractText(from:)).max(by: { $0.count < $1.count })
        }

        if let dictionary = propertyList as? [AnyHashable: Any] {
            return dictionary.values.compactMap(extractText(from:)).max(by: { $0.count < $1.count })
        }

        return nil
    }

    private func readableMessageText(text: String, richBody: String?) -> String? {
        if let richBody, !richBody.isEmpty {
            return richBody
        }

        return validatedMessageText(text)
    }

    private func cleanMessageText(_ text: String) -> String {
        text
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: "\u{fffc}", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedMessageText(_ text: String) -> String? {
        let cleanText = cleanMessageText(text)
        guard cleanText.count >= 1 else { return nil }

        let archiveMarkers = [
            "NSKeyedArchive",
            "NSString",
            "NSObject",
            "NS.objects",
            "NSDictionary",
            "NSMutable",
            "$class",
            "$objects",
            "streamtyped"
        ]

        guard !archiveMarkers.contains(where: { cleanText.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }

        let scalars = cleanText.unicodeScalars
        guard !scalars.isEmpty else { return nil }

        let readableCount = scalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }.count

        let readableRatio = Double(readableCount) / Double(scalars.count)
        return readableRatio >= 0.85 ? cleanText : nil
    }

    private func parseParticipants(_ rawParticipants: String, fallback: String) -> [String] {
        let participants = rawParticipants
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if participants.isEmpty {
            return fallback.isEmpty ? [] : [fallback]
        }

        return participants
    }

    private func mergeParticipants(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        return (lhs + rhs).filter { participant in
            let normalized = participant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized.lowercased()) else { return false }
            seen.insert(normalized.lowercased())
            return true
        }
    }

    private func isUsableReplyHandle(_ handle: String) -> Bool {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.localizedCaseInsensitiveContains("Unknown Thread") else {
            return false
        }

        if trimmed.contains("@") {
            return true
        }

        if trimmed.lowercased().hasPrefix("chat") {
            return false
        }

        let digitCount = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return digitCount >= 7
    }

    private func lastError(_ database: OpaquePointer) -> String {
        guard let cString = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }

        return String(cString: cString)
    }

    private func appleMessageDate(_ rawDate: Int64) -> Date? {
        guard rawDate > 0 else { return nil }

        let appleEpoch = Date(timeIntervalSinceReferenceDate: 0)
        let seconds: TimeInterval

        if rawDate > 10_000_000_000_000_000 {
            seconds = TimeInterval(rawDate) / 1_000_000_000
        } else {
            seconds = TimeInterval(rawDate) / 1_000_000
        }

        return appleEpoch.addingTimeInterval(seconds)
    }

    private func categoryRank(_ category: MessageThread.Category) -> Int {
        switch category {
        case .actionRequired:
            return 0
        case .opportunities:
            return 1
        case .noise:
            return 2
        }
    }
}

final class ContactNameResolver {
    private let store = CNContactStore()
    private var cache: [String: String] = [:]
    private lazy var canReadContacts = Self.requestContactsAccessIfNeeded(store: store)
    private lazy var contactIndex = buildContactIndex()

    func displayName(for handle: String) -> String {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHandle.isEmpty else { return handle }

        let cacheKey = trimmedHandle.lowercased()
        if let cachedName = cache[cacheKey] {
            return cachedName
        }

        guard canReadContacts, let contact = lookupContact(matching: trimmedHandle), let name = formattedName(for: contact) else {
            cache[cacheKey] = trimmedHandle
            return trimmedHandle
        }

        cache[cacheKey] = name
        return name
    }

    private static func requestContactsAccessIfNeeded(store: CNContactStore) -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            return true
        }

        guard status == .notDetermined else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(for: .contacts) { didGrantAccess, _ in
            granted = didGrantAccess
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    }

    private func lookupContact(matching handle: String) -> CNContact? {
        if handle.contains("@") {
            let normalizedEmail = handle.lowercased()
            if let contact = contactIndex.emails[normalizedEmail] {
                return contact
            }

            let predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
            return try? store.unifiedContacts(matching: predicate, keysToFetch: contactKeys).first
        }

        for variant in phoneLookupVariants(for: handle) {
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: variant))
            if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: contactKeys).first {
                return contact
            }
        }

        for key in normalizedPhoneKeys(for: handle) {
            if let contact = contactIndex.phones[key] {
                return contact
            }
        }

        return nil
    }

    private var contactKeys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
    }

    private func buildContactIndex() -> (phones: [String: CNContact], emails: [String: CNContact]) {
        var phones: [String: CNContact] = [:]
        var emails: [String: CNContact] = [:]
        let request = CNContactFetchRequest(keysToFetch: contactKeys)

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                for phoneNumber in contact.phoneNumbers {
                    for key in self.normalizedPhoneKeys(for: phoneNumber.value.stringValue) {
                        phones[key, default: contact] = contact
                    }
                }

                for emailAddress in contact.emailAddresses {
                    let key = String(emailAddress.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !key.isEmpty {
                        emails[key, default: contact] = contact
                    }
                }
            }
        } catch {
            return (phones: [:], emails: [:])
        }

        return (phones: phones, emails: emails)
    }

    private func phoneLookupVariants(for handle: String) -> [String] {
        let digits = digitsOnly(handle)
        var variants = [handle]

        if !digits.isEmpty {
            variants.append(digits)
            variants.append("+\(digits)")
        }

        if digits.count == 11, digits.hasPrefix("1") {
            let localDigits = String(digits.dropFirst())
            variants.append(localDigits)
            variants.append("+1\(localDigits)")
        }

        return unique(variants.filter { !$0.isEmpty })
    }

    private func normalizedPhoneKeys(for value: String) -> [String] {
        let digits = digitsOnly(value)
        guard digits.count >= 7 else { return [] }

        var keys = [digits]

        if digits.count == 11, digits.hasPrefix("1") {
            keys.append(String(digits.dropFirst()))
        }

        if digits.count >= 10 {
            keys.append(String(digits.suffix(10)))
        }

        return unique(keys)
    }

    private func digitsOnly(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !seen.contains(value) else { return false }
            seen.insert(value)
            return true
        }
    }

    private func formattedName(for contact: CNContact) -> String? {
        if let fullName = CNContactFormatter.string(from: contact, style: .fullName), !fullName.isEmpty {
            return fullName
        }

        if !contact.nickname.isEmpty {
            return contact.nickname
        }

        if !contact.organizationName.isEmpty {
            return contact.organizationName
        }

        return nil
    }
}

enum ThreadClassifier {
    static func classify(id: String, name: String, participants: [String], replyHandles: [String], replyService: String, messages: [ThreadMessage]) -> MessageThread {
        let combined = messages.map(\.text).joined(separator: " ")
        let lowercased = combined.lowercased()
        let preview = messages.first?.text ?? ""

        let actionKeywords = ["?", "can you", "could you", "please", "need", "urgent", "today", "tomorrow", "deadline", "due", "send", "sign", "pay", "call", "reply", "confirm", "schedule", "appointment"]
        let opportunityKeywords = ["intro", "referral", "opportunity", "available", "opening", "invite", "meet", "coffee", "client", "project", "interested", "collaborate", "job", "offer"]
        let noiseKeywords = ["delivered", "delivery", "code", "verification", "otp", "receipt", "unsubscribe", "alert", "notification", "package", "tracking"]

        let actionScore = score(lowercased, keywords: actionKeywords)
        let opportunityScore = score(lowercased, keywords: opportunityKeywords)
        let noiseScore = score(lowercased, keywords: noiseKeywords)

        let category: MessageThread.Category
        let suggestedAction: String
        let confidence: Double

        if actionScore >= max(opportunityScore, noiseScore), actionScore > 0 {
            category = .actionRequired
            suggestedAction = "Review and reply"
            confidence = min(0.95, 0.62 + Double(actionScore) * 0.06)
        } else if opportunityScore >= max(actionScore, noiseScore), opportunityScore > 0 {
            category = .opportunities
            suggestedAction = "Check timing and respond"
            confidence = min(0.92, 0.58 + Double(opportunityScore) * 0.06)
        } else {
            category = .noise
            suggestedAction = "Review later"
            confidence = min(0.9, 0.55 + Double(noiseScore) * 0.08)
        }

        let summary = summarize(messages: messages)
        let title = title(for: category, name: name, participants: participants, text: lowercased)

        return MessageThread(
            id: id,
            sender: title,
            participants: participants,
            replyHandles: replyHandles,
            replyService: replyService,
            unreadCount: messages.count,
            preview: preview,
            summary: summary,
            suggestedAction: suggestedAction,
            category: category,
            confidence: confidence,
            messages: messages
        )
    }

    private static func title(for category: MessageThread.Category, name: String, participants: [String], text: String) -> String {
        let participant = compactParticipantLabel(participants, fallback: name)

        switch category {
        case .actionRequired:
            if text.contains("schedule") || text.contains("appointment") {
                return "Schedule With \(participant)"
            }

            if text.contains("sign") {
                return "Sign And Return"
            }

            if text.contains("pay") || text.contains("payment") {
                return "Payment For \(participant)"
            }

            if text.contains("send") {
                return "Send Requested Item"
            }

            if text.contains("call") {
                return "Call \(participant) Back"
            }

            return "Reply To \(participant)"
        case .opportunities:
            if text.contains("intro") || text.contains("referral") {
                return "Referral From \(participant)"
            }

            if text.contains("meet") || text.contains("coffee") {
                return "Meeting With \(participant)"
            }

            if text.contains("job") || text.contains("offer") {
                return "Offer From \(participant)"
            }

            return "Opportunity With \(participant)"
        case .noise:
            if text.contains("delivery") || text.contains("package") || text.contains("tracking") {
                return "Delivery Alert Updates"
            }

            if text.contains("code") || text.contains("verification") || text.contains("otp") {
                return "Verification Code Updates"
            }

            return "Updates From \(participant)"
        }
    }

    private static func compactParticipantLabel(_ participants: [String], fallback: String) -> String {
        let names = participants
            .map(shortDisplayName)
            .filter { !$0.isEmpty }

        if names.count >= 2 {
            return "\(names[0]) And \(names[1])"
        }

        if let firstName = names.first {
            return firstName
        }

        let fallbackName = shortDisplayName(fallback)
        return fallbackName.isEmpty ? "Participant" : fallbackName
    }

    private static func shortDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("@") {
            return ""
        }

        let digitCount = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if digitCount >= 7 {
            return ""
        }

        return trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init) ?? ""
    }

    private static func score(_ text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { partial, keyword in
            text.contains(keyword) ? partial + 1 : partial
        }
    }

    private static func summarize(messages: [ThreadMessage]) -> String {
        let snippets = messages
            .map(\.text)
            .prefix(3)

        guard !snippets.isEmpty else {
            return "No readable text messages were found in this thread."
        }

        return "Text summary from \(messages.count) message\(messages.count == 1 ? "" : "s"): \(snippets.joined(separator: " / "))"
    }
}

struct TriageDashboardView: View {
    @StateObject private var store = ThreadTriageStore()
    @State private var selectedCategory: MessageThread.Category = .actionRequired
    @State private var selectedThreadID: MessageThread.ID?
    @State private var isShowingHelp = false

    var filteredThreads: [MessageThread] {
        store.threads.filter { $0.category == selectedCategory }
    }

    var selectedThread: MessageThread? {
        store.threads.first { $0.id == selectedThreadID } ?? filteredThreads.first
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedCategory) {
                    ForEach(MessageThread.Category.allCases) { category in
                        Label {
                            Text(category.rawValue)
                        } icon: {
                            Image(systemName: iconName(for: category))
                        }
                        .badge(store.threads.filter { $0.category == category }.count)
                        .tag(category)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        isShowingHelp = true
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        store.loadLocalMessages()
                    } label: {
                        Label("Load Local Messages", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.loadState == .loading)

                    LoadStateView(state: store.loadState)
                }
                .padding()
            }
            .navigationTitle("ThreadPilot")
        } content: {
            List(filteredThreads, selection: $selectedThreadID) { thread in
                ThreadRow(thread: thread)
                    .padding(.vertical, 6)
            }
            .navigationTitle(selectedCategory.rawValue)
        } detail: {
            if let selectedThread {
                ThreadDetailView(thread: selectedThread) {
                    store.markThreadHandled(selectedThread.id)
                }
            } else {
                ThreadDetailPlaceholder(category: selectedCategory)
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpCenterView()
        }
        .alert(item: $store.permissionPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text("Open System Settings")) {
                    PermissionSettings.openFullDiskAccess()
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    private func iconName(for category: MessageThread.Category) -> String {
        switch category {
        case .actionRequired:
            return "checklist"
        case .opportunities:
            return "sparkles"
        case .noise:
            return "speaker.slash"
        }
    }
}

struct LoadStateView: View {
    let state: MessagesLoadState

    var body: some View {
        switch state {
        case .idle:
            Text("Uses unread or recent messages from this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading Messages locally...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .loaded(let count):
            Text("Loaded \(count) unread thread\(count == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum PermissionSettings {
    static func openFullDiskAccess() {
        let urlStrings = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

struct ResponseSettingsView: View {
    @AppStorage(ResponseSettings.approveKey) private var approveMessage = ResponseSettings.approveDefault
    @AppStorage(ResponseSettings.rejectKey) private var rejectMessage = ResponseSettings.rejectDefault
    @AppStorage(ResponseSettings.discussKey) private var discussMessage = ResponseSettings.discussDefault
    @AppStorage(ResponseSettings.completedKey) private var completedMessage = ResponseSettings.completedDefault
    @AppStorage(ResponseSettings.workingKey) private var workingMessage = ResponseSettings.workingDefault
    @AppStorage(ResponseSettings.notStartedKey) private var notStartedMessage = ResponseSettings.notStartedDefault
    @AppStorage(ResponseSettings.yesKey) private var yesMessage = ResponseSettings.yesDefault
    @AppStorage(ResponseSettings.noKey) private var noMessage = ResponseSettings.noDefault
    @AppStorage(ResponseSettings.interestedKey) private var interestedMessage = ResponseSettings.interestedDefault
    @AppStorage(ResponseSettings.notInterestedKey) private var notInterestedMessage = ResponseSettings.notInterestedDefault

    var body: some View {
        Form {
            Section("Action Required Responses") {
                TextField("Approve", text: $approveMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Reject", text: $rejectMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Discuss", text: $discussMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Completed", text: $completedMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Working", text: $workingMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Not Started", text: $notStartedMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Yes", text: $yesMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("No", text: $noMessage, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Opportunity Responses") {
                TextField("Interested", text: $interestedMessage, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Not Interested", text: $notInterestedMessage, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Button("Restore Defaults") {
                    approveMessage = ResponseSettings.approveDefault
                    rejectMessage = ResponseSettings.rejectDefault
                    discussMessage = ResponseSettings.discussDefault
                    completedMessage = ResponseSettings.completedDefault
                    workingMessage = ResponseSettings.workingDefault
                    notStartedMessage = ResponseSettings.notStartedDefault
                    yesMessage = ResponseSettings.yesDefault
                    noMessage = ResponseSettings.noDefault
                    interestedMessage = ResponseSettings.interestedDefault
                    notInterestedMessage = ResponseSettings.notInterestedDefault
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

struct HelpEntry: Identifiable {
    let id = UUID()
    let title: String
    let keywords: [String]
    let body: String
}

struct HelpCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    private let entries = HelpContent.entries
    let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private var filteredEntries: [HelpEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }

        return entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
                || entry.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.keywords.prefix(4).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Help")
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search help")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        if let icon = AppIconLoader.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("ThreadPilot Help")
                                .font(.largeTitle.weight(.semibold))

                            Text("Searchable instructions for triaging and responding to message threads.")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Done") {
                            if let onClose {
                                onClose()
                            } else {
                                dismiss()
                            }
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    if filteredEntries.isEmpty {
                        ContentUnavailableView("No Help Results", systemImage: "magnifyingglass", description: Text("Try searching for privacy, permissions, categories, summaries, or quick actions."))
                    } else {
                        ForEach(filteredEntries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.title)
                                    .font(.title2.weight(.semibold))

                                Text(entry.body)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(entry.keywords.joined(separator: "  "))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
                .padding(28)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

enum HelpContent {
    static let entries: [HelpEntry] = [
        HelpEntry(
            title: "How To Use ThreadPilot",
            keywords: ["instructions", "how to", "workflow", "steps", "start"],
            body: "Start with Load Local Messages. Choose a triage lane on the left: Action Required, Opportunities, or Noise. Select a thread to review participants, the summary, suggested action, confidence, and readable messages. Use Read Aloud to hear the summary. Use a quick action or Custom response when you are ready. Actions that send, dismiss, or complete a thread mark it as read and remove it from the active list."
        ),
        HelpEntry(
            title: "What ThreadPilot Does",
            keywords: ["overview", "purpose", "triage", "messages", "inbox"],
            body: "ThreadPilot helps organize unread or recently active message threads so important conversations do not get buried. It groups threads by whether they require action, may contain an opportunity, or are likely noise."
        ),
        HelpEntry(
            title: "Thread Categories",
            keywords: ["action required", "opportunities", "noise", "classification", "lanes"],
            body: "Action Required is for threads that need a reply, decision, payment, scheduling, confirmation, or follow-up. Opportunities is for invitations, referrals, warm leads, reconnect moments, and time-sensitive possibilities. Noise is for low-value updates, confirmations, automated messages, and threads that can wait."
        ),
        HelpEntry(
            title: "Loading Messages From This Mac",
            keywords: ["load", "messages", "mac", "chat.db", "full disk access", "permissions"],
            body: "Use Load Local Messages to read unread or recent Messages data from this Mac. macOS protects the Messages database, so ThreadPilot may need Full Disk Access when you choose this advanced local mode. The app does not imply automatic iPhone Messages access."
        ),
        HelpEntry(
            title: "Privacy And Local Processing",
            keywords: ["privacy", "local", "cloud", "ai", "upload", "permission"],
            body: "ThreadPilot is designed around local processing by default. Message content should never be uploaded to cloud AI services without explicit user approval. Any cloud processing should be opt-in, clearly labeled, and auditable."
        ),
        HelpEntry(
            title: "Summaries And Suggested Actions",
            keywords: ["summary", "suggested action", "confidence", "unread count", "important messages"],
            body: "Each thread displays a short text-only summary, unread count, suggested action, confidence score, participants, and readable messages. Summaries are based on the cleaned text content of the thread."
        ),
        HelpEntry(
            title: "Read Aloud",
            keywords: ["read aloud", "speech", "summary", "speaker", "accessibility"],
            body: "Use Read Aloud in the Summary section to hear the current thread summary. The button changes to Stop while the summary is being spoken and stops automatically when you switch threads."
        ),
        HelpEntry(
            title: "Quick Responses",
            keywords: ["approve", "reject", "completed", "working", "yes", "no", "interested", "dismiss"],
            body: "Quick responses are available based on the thread category. Action Required includes approval and status responses. Opportunities includes Interested and Not Interested. Noise includes Respond and Dismiss. Sending or dismissing a thread marks it as read."
        ),
        HelpEntry(
            title: "Custom Responses And Dictation",
            keywords: ["custom", "dictate", "microphone", "speech recognition", "reply"],
            body: "Use Custom to type a reply or dictate one using speech-to-text. Dictation requires microphone and speech-recognition permission from macOS. After a custom response is sent, ThreadPilot marks the thread as read."
        ),
        HelpEntry(
            title: "Contacts And Participants",
            keywords: ["contacts", "participants", "names", "phone numbers", "email"],
            body: "ThreadPilot can ask for Contacts access to display participant names instead of raw phone numbers or email addresses. It normalizes phone-number formats to improve matching against Contacts."
        ),
        HelpEntry(
            title: "Limits And Non-Goals",
            keywords: ["limits", "iphone", "non-goals", "sending", "history", "messages"],
            body: "Apple does not provide a public iOS API for automatic full-history scanning of Messages. ThreadPilot targets macOS workflows with explicit permission or imported data. The product spec does not treat ThreadPilot as a replacement for Apple Messages."
        )
    ]
}

struct ThreadRow: View {
    let thread: MessageThread

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(thread.sender)
                    .font(.headline)
                Spacer()
                Text("\(thread.unreadCount) unread")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(thread.participants.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(thread.summary)
                .font(.subheadline)
                .lineLimit(2)

            HStack {
                Label(thread.suggestedAction, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(thread.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ThreadDetailPlaceholder: View {
    let category: MessageThread.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(category.rawValue)
                .font(.largeTitle.weight(.semibold))

            Text("Select a thread to review its summary, important messages, extracted dates, and suggested next step.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)

            Spacer()
        }
        .padding(32)
    }
}

struct ThreadDetailView: View {
    let thread: MessageThread
    let onThreadHandled: () -> Void
    @State private var replyState: ThreadReplyState = .idle
    @StateObject private var summarySpeaker = ThreadSummarySpeaker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.sender)
                        .font(.largeTitle.weight(.semibold))
                    Spacer()
                    Text(thread.category.rawValue)
                        .font(.headline)
                        .foregroundStyle(categoryColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Participants")
                        .font(.headline)
                    Text(thread.participants.joined(separator: ", "))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Summary")
                            .font(.headline)

                        Spacer()

                        Button {
                            if summarySpeaker.isSpeaking {
                                summarySpeaker.stop()
                            } else {
                                summarySpeaker.speak(thread.summary)
                            }
                        } label: {
                            Label(
                                summarySpeaker.isSpeaking ? "Stop" : "Read Aloud",
                                systemImage: summarySpeaker.isSpeaking ? "stop.circle" : "speaker.wave.2"
                            )
                        }
                        .disabled(thread.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(summarySpeaker.isSpeaking ? "Stop reading the summary" : "Read the thread summary aloud")
                    }

                    Text(thread.summary)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested Action")
                        .font(.headline)
                    Label(thread.suggestedAction, systemImage: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                }

                CustomResponseControls(thread: thread, replyState: $replyState, onThreadHandled: onThreadHandled)

                if thread.category == .actionRequired {
                    ActionRequiredControls(thread: thread, replyState: $replyState, onThreadHandled: onThreadHandled)
                }

                if thread.category == .opportunities {
                    OpportunityControls(thread: thread, replyState: $replyState, onThreadHandled: onThreadHandled)
                }

                if thread.category == .noise {
                    NoiseControls(thread: thread, replyState: $replyState, onThreadHandled: onThreadHandled)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Unread Messages")
                        .font(.headline)

                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(message.sender)
                                    .font(.caption.weight(.semibold))
                                    .textSelection(.enabled)
                                Text(message.service.isEmpty ? "Message" : message.service)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let date = message.date {
                                    Text(date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(message.text)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(32)
        }
        .onChange(of: thread.id) { _, _ in
            summarySpeaker.stop()
        }
        .onDisappear {
            summarySpeaker.stop()
        }
    }

    private var categoryColor: Color {
        switch thread.category {
        case .actionRequired:
            return .red
        case .opportunities:
            return .orange
        case .noise:
            return .secondary
        }
    }
}

enum ThreadReplyState: Equatable {
    case idle
    case sending(String)
    case sent(String)
    case failed(String)
}

@MainActor
final class DictationController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var dictatedText = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func toggle() {
        isRecording ? stop() : requestAccessAndStart()
    }

    func stop() {
        guard isRecording else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    private func requestAccessAndStart() {
        errorMessage = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard speechStatus == .authorized else {
                Task { @MainActor in
                    self?.errorMessage = "Allow speech recognition to dictate a response."
                }
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
                Task { @MainActor in
                    guard microphoneAllowed else {
                        self?.errorMessage = "Allow microphone access to dictate a response."
                        return
                    }

                    self?.start()
                }
            }
        }
    }

    private func start() {
        guard !audioEngine.isRunning else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now."
            return
        }

        dictatedText = ""
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.dictatedText = result.bestTranscription.formattedString
                }

                if let error {
                    self?.errorMessage = error.localizedDescription
                    self?.stop()
                    return
                }

                if result?.isFinal == true {
                    self?.stop()
                }
            }
        }
    }
}

enum ThreadResponseAction: String, CaseIterable, Identifiable {
    case approve = "Approve"
    case reject = "Reject"
    case discuss = "Discuss"
    case completed = "Completed"
    case working = "Working"
    case notStarted = "Not Started"
    case yes = "Yes"
    case no = "No"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .approve:
            return "checkmark.circle"
        case .reject:
            return "xmark.circle"
        case .discuss:
            return "calendar.badge.clock"
        case .completed:
            return "checkmark.seal"
        case .working:
            return "hammer"
        case .notStarted:
            return "calendar.badge.plus"
        case .yes:
            return "hand.thumbsup"
        case .no:
            return "hand.thumbsdown"
        }
    }

    func message(
        approve: String,
        reject: String,
        discuss: String,
        completed: String,
        working: String,
        notStarted: String,
        yes: String,
        no: String
    ) -> String {
        switch self {
        case .approve:
            return approve
        case .reject:
            return reject
        case .discuss:
            return discuss
        case .completed:
            return completed
        case .working:
            return working
        case .notStarted:
            return notStarted
        case .yes:
            return yes
        case .no:
            return no
        }
    }
}

enum OpportunityResponseAction: String, CaseIterable, Identifiable {
    case interested = "Interested"
    case notInterested = "Not Interested"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .interested:
            return "hand.thumbsup"
        case .notInterested:
            return "hand.thumbsdown"
        }
    }

    func message(interested: String, notInterested: String) -> String {
        switch self {
        case .interested:
            return interested
        case .notInterested:
            return notInterested
        }
    }
}

struct CustomResponseControls: View {
    let thread: MessageThread
    @Binding var replyState: ThreadReplyState
    let onThreadHandled: () -> Void
    @State private var isShowingResponseSheet = false
    @State private var responseMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Response")
                .font(.headline)

            Button {
                responseMessage = ""
                isShowingResponseSheet = true
            } label: {
                Label("Custom", systemImage: "text.bubble")
            }
            .disabled(isSending || !thread.canReply)

            switch replyState {
            case .idle:
                if !thread.canReply {
                    Text("No reply handle was found for this thread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sending(let actionName):
                if actionName == "Custom" {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Sending custom response...")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .sent(let actionName):
                if actionName == "Custom" {
                    Label("Custom response sent.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingResponseSheet) {
            CustomResponseSheet(
                message: $responseMessage,
                isSending: isSending,
                onCancel: {
                    isShowingResponseSheet = false
                },
                onSend: {
                    send()
                }
            )
        }
    }

    private var isSending: Bool {
        if case .sending = replyState {
            return true
        }

        return false
    }

    private func send() {
        let message = responseMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            replyState = .failed("Enter a custom response before sending.")
            return
        }

        isShowingResponseSheet = false
        replyState = .sending("Custom")
        Task {
            do {
                try await ThreadReplySender.send(message: message, to: thread)
                try await ThreadReadMarker.markRead(thread)
                onThreadHandled()
                replyState = .sent("Custom")
            } catch {
                replyState = .failed(error.localizedDescription)
            }
        }
    }
}

struct CustomResponseSheet: View {
    @Binding var message: String
    let isSending: Bool
    let onCancel: () -> Void
    let onSend: () -> Void
    @StateObject private var dictation = DictationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Response")
                .font(.title2.weight(.semibold))

            TextEditor(text: $message)
                .frame(width: 460, height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )

            HStack(spacing: 10) {
                Button {
                    dictation.toggle()
                } label: {
                    Label(dictation.isRecording ? "Stop Dictation" : "Dictate", systemImage: dictation.isRecording ? "stop.circle" : "mic")
                }
                .disabled(isSending)

                if dictation.isRecording {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Listening...")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let errorMessage = dictation.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dictation.stop()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Send") {
                    dictation.stop()
                    onSend()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .onChange(of: dictation.dictatedText) { _, dictatedText in
            guard !dictatedText.isEmpty else { return }
            message = dictatedText
        }
        .onDisappear {
            dictation.stop()
        }
    }
}

struct ActionRequiredControls: View {
    let thread: MessageThread
    @Binding var replyState: ThreadReplyState
    let onThreadHandled: () -> Void

    @AppStorage(ResponseSettings.approveKey) private var approveMessage = ResponseSettings.approveDefault
    @AppStorage(ResponseSettings.rejectKey) private var rejectMessage = ResponseSettings.rejectDefault
    @AppStorage(ResponseSettings.discussKey) private var discussMessage = ResponseSettings.discussDefault
    @AppStorage(ResponseSettings.completedKey) private var completedMessage = ResponseSettings.completedDefault
    @AppStorage(ResponseSettings.workingKey) private var workingMessage = ResponseSettings.workingDefault
    @AppStorage(ResponseSettings.notStartedKey) private var notStartedMessage = ResponseSettings.notStartedDefault
    @AppStorage(ResponseSettings.yesKey) private var yesMessage = ResponseSettings.yesDefault
    @AppStorage(ResponseSettings.noKey) private var noMessage = ResponseSettings.noDefault
    private let actionColumns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Response")
                .font(.headline)

            LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 8) {
                ForEach(ThreadResponseAction.allCases) { action in
                    Button {
                        send(action)
                    } label: {
                        Label(action.rawValue, systemImage: action.iconName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isSending || !thread.canReply)
                }
            }

            switch replyState {
            case .idle:
                if !thread.canReply {
                    Text("No reply handle was found for this thread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sending(let actionName):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending \(actionName.lowercased()) response...")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .sent(let actionName):
                Label("\(actionName) response sent.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isSending: Bool {
        if case .sending = replyState {
            return true
        }

        return false
    }

    private func send(_ action: ThreadResponseAction) {
        let message = action.message(
            approve: approveMessage,
            reject: rejectMessage,
            discuss: discussMessage,
            completed: completedMessage,
            working: workingMessage,
            notStarted: notStartedMessage,
            yes: yesMessage,
            no: noMessage
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            replyState = .failed("The \(action.rawValue.lowercased()) response is empty. Update it in Settings.")
            return
        }

        replyState = .sending(action.rawValue)
        Task {
            do {
                try await ThreadReplySender.send(message: message, to: thread)
                try await ThreadReadMarker.markRead(thread)
                onThreadHandled()
                replyState = .sent(action.rawValue)
            } catch {
                replyState = .failed(error.localizedDescription)
            }
        }
    }
}

struct OpportunityControls: View {
    let thread: MessageThread
    @Binding var replyState: ThreadReplyState
    let onThreadHandled: () -> Void

    @AppStorage(ResponseSettings.interestedKey) private var interestedMessage = ResponseSettings.interestedDefault
    @AppStorage(ResponseSettings.notInterestedKey) private var notInterestedMessage = ResponseSettings.notInterestedDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Response")
                .font(.headline)

            HStack(spacing: 8) {
                ForEach(OpportunityResponseAction.allCases) { action in
                    Button {
                        send(action)
                    } label: {
                        Label(action.rawValue, systemImage: action.iconName)
                    }
                    .disabled(isSending || !thread.canReply)
                }
            }

            switch replyState {
            case .idle:
                if !thread.canReply {
                    Text("No reply handle was found for this thread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sending(let actionName):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending \(actionName.lowercased()) response...")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .sent(let actionName):
                Label("\(actionName) response sent.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isSending: Bool {
        if case .sending = replyState {
            return true
        }

        return false
    }

    private func send(_ action: OpportunityResponseAction) {
        let message = action.message(interested: interestedMessage, notInterested: notInterestedMessage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            replyState = .failed("The \(action.rawValue.lowercased()) response is empty. Update it in Settings.")
            return
        }

        replyState = .sending(action.rawValue)
        Task {
            do {
                try await ThreadReplySender.send(message: message, to: thread)
                try await ThreadReadMarker.markRead(thread)
                onThreadHandled()
                replyState = .sent(action.rawValue)
            } catch {
                replyState = .failed(error.localizedDescription)
            }
        }
    }
}

struct NoiseControls: View {
    let thread: MessageThread
    @Binding var replyState: ThreadReplyState
    let onThreadHandled: () -> Void
    @State private var isShowingResponseSheet = false
    @State private var responseMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Response")
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    responseMessage = ""
                    isShowingResponseSheet = true
                } label: {
                    Label("Respond", systemImage: "arrowshape.turn.up.left")
                }
                .disabled(isSending || !thread.canReply)

                Button {
                    dismissThread()
                } label: {
                    Label("Dismiss", systemImage: "checkmark")
                }
                .disabled(isSending)
            }

            switch replyState {
            case .idle:
                if !thread.canReply {
                    Text("No reply handle was found for this thread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sending(let actionName):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(actionName)...")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .sent(let actionName):
                Label("\(actionName) complete.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingResponseSheet) {
            NoiseResponseSheet(
                message: $responseMessage,
                isSending: isSending,
                onCancel: {
                    isShowingResponseSheet = false
                },
                onSend: {
                    respond()
                }
            )
        }
    }

    private var isSending: Bool {
        if case .sending = replyState {
            return true
        }

        return false
    }

    private func respond() {
        let message = responseMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            replyState = .failed("Enter a response before sending.")
            return
        }

        isShowingResponseSheet = false
        replyState = .sending("Sending response")
        Task {
            do {
                try await ThreadReplySender.send(message: message, to: thread)
                try await ThreadReadMarker.markRead(thread)
                onThreadHandled()
                replyState = .sent("Response")
            } catch {
                replyState = .failed(error.localizedDescription)
            }
        }
    }

    private func dismissThread() {
        replyState = .sending("Dismissing thread")
        Task {
            do {
                try await ThreadReadMarker.markRead(thread)
                onThreadHandled()
                replyState = .sent("Dismiss")
            } catch {
                replyState = .failed(error.localizedDescription)
            }
        }
    }
}

struct NoiseResponseSheet: View {
    @Binding var message: String
    let isSending: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Respond")
                .font(.title2.weight(.semibold))

            TextEditor(text: $message)
                .frame(width: 420, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reply", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }
}

enum ThreadReplyError: LocalizedError {
    case missingRecipient
    case osascriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRecipient:
            return "No Messages recipient was available for this thread."
        case .osascriptFailed(let message):
            return "Messages could not send the response: \(message)"
        }
    }
}

enum ThreadReadMarker {
    static func markRead(_ thread: MessageThread) async throws {
        try await Task.detached {
            try MessagesDatabaseLoader().markThreadRead(threadID: thread.id)
        }.value
    }
}

enum ThreadReplySender {
    static func send(message: String, to thread: MessageThread) async throws {
        try await Task.detached {
            guard let recipient = thread.replyHandles.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ThreadReplyError.missingRecipient
            }

            let script = """
            on run argv
                set responseText to item 1 of argv
                set chatIdentifier to item 2 of argv
                set recipientHandle to item 3 of argv
                tell application "Messages"
                    if chatIdentifier is not "" then
                        try
                            send responseText to chat id chatIdentifier
                            return "sent to chat"
                        end try
                    end if
                    set targetService to missing value
                    try
                        set targetService to 1st service whose service type = iMessage
                    end try
                    if targetService is missing value then
                        error "No iMessage service is available."
                    end if
                    send responseText to buddy recipientHandle of targetService
                    return "sent to buddy"
                end tell
            end run
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--", message, thread.id, recipient]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData + outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ThreadReplyError.osascriptFailed(errorText?.isEmpty == false ? errorText! : "Unknown AppleScript error.")
            }
        }.value
    }
}

private extension MessageThread {
    var canReply: Bool {
        !replyHandles.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension MessageThread {
    static let samples: [MessageThread] = [
        MessageThread(
            id: "sample-jordan",
            sender: "Jordan",
            participants: ["Jordan"],
            replyHandles: ["jordan@example.com"],
            replyService: "iMessage",
            unreadCount: 6,
            preview: "Can you send the signed copy before 3?",
            summary: "Jordan is waiting on a signed document today and has asked twice for confirmation.",
            suggestedAction: "Send document or reply with ETA",
            category: .actionRequired,
            confidence: 0.91,
            messages: [
                ThreadMessage(sender: "Jordan", text: "Can you send the signed copy before 3?", date: nil, service: "iMessage")
            ]
        ),
        MessageThread(
            id: "sample-maya",
            sender: "Maya",
            participants: ["Maya"],
            replyHandles: ["maya@example.com"],
            replyService: "iMessage",
            unreadCount: 3,
            preview: "We may have an opening next Tuesday.",
            summary: "Maya mentioned a possible client intro and asked whether next Tuesday works.",
            suggestedAction: "Confirm availability",
            category: .opportunities,
            confidence: 0.84,
            messages: [
                ThreadMessage(sender: "Maya", text: "We may have an opening next Tuesday.", date: nil, service: "iMessage")
            ]
        ),
        MessageThread(
            id: "sample-delivery",
            sender: "Delivery Alerts",
            participants: ["Delivery Alerts"],
            replyHandles: [],
            replyService: "SMS",
            unreadCount: 9,
            preview: "Your package is nearby.",
            summary: "Automated delivery status updates with no reply needed.",
            suggestedAction: "Archive or mute",
            category: .noise,
            confidence: 0.96,
            messages: [
                ThreadMessage(sender: "Delivery Alerts", text: "Your package is nearby.", date: nil, service: "SMS")
            ]
        )
    ]
}
