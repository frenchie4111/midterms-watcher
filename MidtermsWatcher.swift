// Midterms Watcher — a menu bar app that watches the 2026 midterms.
//
// Odds come from Polymarket (gamma API for markets, CLOB for today's price history).
// Live vote counts and seat tallies come from the NYT's public results JSON
// (AP-sourced). Every race row expands into a chart of today's odds, the current
// vote count, and a vote-share-over-time chart built from snapshots this app
// records locally (~/Library/Application Support/MidtermsWatcher/).
//
// Notifies on >= alertThreshold odds moves, leader changes, and AP calls.
//
// Build with ./build.sh (or install with ./install.sh). `--window` opens the panel
// in a normal window (handy for screenshots/debugging).

import AppKit
import Charts
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Config

let refreshInterval: TimeInterval = 60
let alertThreshold = 0.05  // 5 points
// Override to e.g. 2024-11-05 to exercise the vote UI against a past night's NYT files.
let electionDate = ProcessInfo.processInfo.environment["MIDTERMS_RESULTS_DATE"] ?? "2026-11-03"
let headlineSlugs = [
    "which-party-will-win-the-house-in-2026",
    "which-party-will-win-the-senate-in-2026",
    "balance-of-power-2026-midterms",
]
let collapsedRaceCount = 12  // per section, before "Show all"

let states: [String: String] = [
    "Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA",
    "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "Florida": "FL", "Georgia": "GA",
    "Hawaii": "HI", "Idaho": "ID", "Illinois": "IL", "Indiana": "IN", "Iowa": "IA", "Kansas": "KS",
    "Kentucky": "KY", "Louisiana": "LA", "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA",
    "Michigan": "MI", "Minnesota": "MN", "Mississippi": "MS", "Missouri": "MO", "Montana": "MT",
    "Nebraska": "NE", "Nevada": "NV", "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM",
    "New York": "NY", "North Carolina": "NC", "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK",
    "Oregon": "OR", "Pennsylvania": "PA", "Rhode Island": "RI", "South Carolina": "SC",
    "South Dakota": "SD", "Tennessee": "TN", "Texas": "TX", "Utah": "UT", "Vermont": "VT",
    "Virginia": "VA", "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI", "Wyoming": "WY",
]

// MARK: - Polymarket API models

struct APIEvent: Decodable {
    let id: String
    let slug: String
    let title: String
    let volume: Double?
    let closed: Bool?
    let markets: [APIMarket]?
}

struct APIMarket: Decodable {
    let id: String
    let groupItemTitle: String?
    let outcomePrices: String?  // JSON-encoded array of strings, e.g. "[\"0.94\", \"0.06\"]"
    let oneDayPriceChange: Double?
    let closed: Bool?
    let image: String?
    let clobTokenIds: String?  // JSON-encoded array; first is the "Yes" token

    private func decodeArray(_ s: String?) -> [String]? {
        s?.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }
    var yesToken: String? { decodeArray(clobTokenIds)?.first }
    var yesPrice: Double? { decodeArray(outcomePrices)?.first.flatMap(Double.init) }
}

struct PricePoint: Decodable {
    let t: Double  // unix seconds
    let p: Double
    var date: Date { Date(timeIntervalSince1970: t) }
}

// MARK: - NYT results models (decoded with .convertFromSnakeCase)

struct NYTFile: Decodable {
    let races: [NYTRace]
    let partyControlData: NYTControl?
}

struct NYTRace: Decodable {
    let officeId: String
    let candidateMetadata: [String: NYTCandidate]
    let outcome: NYTOutcome?
    let topReportingUnit: NYTUnit
}

struct NYTCandidate: Decodable {
    let firstName: String?
    let lastName: String?
    let party: NYTParty?
}

struct NYTParty: Decodable { let nytId: String? }
struct NYTOutcome: Decodable { let won: [String]? }

struct NYTUnit: Decodable {
    let statePostal: String
    let eevp: Double?
    let totalVotes: Double?
    let candidates: [NYTUnitCandidate]
}

struct NYTUnitCandidate: Decodable {
    let nytId: String
    let votes: NYTVotes?
}

struct NYTVotes: Decodable { let total: Double? }

struct NYTControl: Decodable {
    struct Result: Decodable { let offices: [String: NYTOffice] }
    let results: [Result]
}

struct NYTOffice: Decodable {
    struct Balance: Decodable { let seats: Int?; let winner: Bool? }
    let total: Int?
    let numRacesCalled: Int?
    let toWin: [String: Int]?
    let partyBalance: [String: Balance]?
}

// MARK: - Theme

enum Theme {
    static let blue = Color(red: 0.22, green: 0.48, blue: 0.96)
    static let red = Color(red: 0.91, green: 0.26, blue: 0.29)
    static let purple = Color(red: 0.58, green: 0.45, blue: 0.88)
    static let gold = Color(red: 0.90, green: 0.68, blue: 0.22)
    static let teal = Color(red: 0.18, green: 0.70, blue: 0.68)
    static let slate = Color(red: 0.50, green: 0.58, blue: 0.70)
    static let up = Color(red: 0.22, green: 0.78, blue: 0.47)
    static let down = Color(red: 0.95, green: 0.38, blue: 0.32)
    static let card = Color.primary.opacity(0.045)
}

// MARK: - View models

enum Party: String, Codable {
    case dem, rep, other

    init(name: String) {
        let n = name.lowercased()
        if n.contains("(d)") || n.contains("democrat") { self = .dem }
        else if n.contains("(r)") || n.contains("republican") { self = .rep }
        else { self = .other }
    }

    init(nyt code: String?) {
        switch code {
        case "DEM": self = .dem
        case "GOP": self = .rep
        default: self = .other
        }
    }

    var color: Color {
        switch self {
        case .dem: return Theme.blue
        case .rep: return Theme.red
        case .other: return Theme.purple
        }
    }

    var letter: String {
        switch self { case .dem: return "D"; case .rep: return "R"; case .other: return "I" }
    }
}

struct Outcome: Identifiable {
    let id: String
    let name: String
    let price: Double
    let change24h: Double?
    let token: String?
    let image: URL?

    var party: Party { Party(name: name) }
    /// "James Talarico (D)" -> "Talarico"
    var lastName: String {
        let base = name.components(separatedBy: " (").first ?? name
        return base.split(separator: " ").last.map(String.init) ?? base
    }
}

enum Category: String, CaseIterable {
    case headline = "Control"
    case senate = "Senate"
    case governor = "Governor"
    case house = "House Races"

    var icon: String {
        switch self {
        case .headline: return "scale.3d"
        case .senate: return "building.columns.fill"
        case .governor: return "star.circle.fill"
        case .house: return "house.fill"
        }
    }

    var tint: Color {
        switch self {
        case .headline: return Theme.purple
        case .senate: return Theme.gold
        case .governor: return Theme.teal
        case .house: return Theme.slate
        }
    }

    static func of(_ e: APIEvent) -> Category? {
        if headlineSlugs.contains(e.slug) { return .headline }
        let t = e.title
        guard t.contains("Election Winner") else { return nil }
        if t.contains("Senate") { return .senate }
        if t.contains("Governor") { return .governor }
        if t.contains("House") { return .house }
        return nil
    }
}

struct Race: Identifiable {
    let id: String
    let slug: String
    let title: String
    let category: Category
    let volume: Double
    let closed: Bool
    let outcomes: [Outcome]  // sorted by price desc

    var leader: Outcome? { outcomes.first }
    var url: URL { URL(string: "https://polymarket.com/event/\(slug)")! }

    var shortTitle: String {
        title.replacingOccurrences(of: " Election Winner", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Key into Store.votes, e.g. "TX-S" / "OH-G". Nil for headline and House district markets.
    var voteKey: String? {
        let office: String
        switch category {
        case .senate: office = "S"
        case .governor: office = "G"
        default: return nil
        }
        let name = shortTitle.replacingOccurrences(of: " Senate", with: "").replacingOccurrences(of: " Governor", with: "")
        return states[name].map { "\($0)-\(office)" }
    }
}

struct VoteCandidate: Identifiable, Codable {
    let id: String
    let name: String  // last name
    let fullName: String
    let party: Party
    let votes: Double
    let share: Double  // 0...1
    let won: Bool
}

struct VoteResult {
    let eevp: Double  // 0...100, NYT's estimated % of expected vote counted
    let totalVotes: Double
    let candidates: [VoteCandidate]  // sorted by votes desc

    var winner: VoteCandidate? { candidates.first(where: \.won) }
    var hasVotes: Bool { totalVotes > 0 }
}

struct VoteSnapshot: Codable {
    let t: Date
    let eevp: Double
    let shares: [String: Double]  // candidate id -> share
}

struct SeatTally {
    let dem: Int
    let rep: Int
    let total: Int
    let toWin: Int
    let called: Int
    let winner: Party?
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var races: [Category: [Race]] = [:]
    @Published var votes: [String: VoteResult] = [:]
    @Published var voteHistory: [String: [VoteSnapshot]] = [:]
    @Published var seats: [String: SeatTally] = [:]  // "H" / "S"
    @Published var priceHistory: [String: [PricePoint]] = [:]  // keyed by token id
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var alertsEnabled = UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") }
    }

    var expandedRaces: Set<String> = []  // race ids whose price history we keep fresh

    // Leader price at the time of the last alert (or first sighting), per race.
    private var baseline: [String: (name: String, price: Double, closed: Bool)] = [:]
    private var announcedCalls: Set<String> = []
    private var firstVoteLoad = true
    private var timer: Timer?

    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MidtermsWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("votes-\(electionDate).json")
    }()

    private init() {
        if let data = try? Data(contentsOf: historyURL),
           let h = try? JSONDecoder().decode([String: [VoteSnapshot]].self, from: data) {
            voteHistory = h
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { await Store.shared.refresh() }
        }
    }

    func race(_ slug: String) -> Race? {
        races[.headline]?.first { $0.slug == slug }
    }

    var menuBarTitle: String {
        func part(_ label: String, _ slug: String) -> String? {
            guard let l = race(slug)?.leader else { return nil }
            return "\(label) \(l.party.letter)\(Int((l.price * 100).rounded()))"
        }
        let parts = [part("H", headlineSlugs[0]), part("S", headlineSlugs[1])].compactMap { $0 }
        return parts.isEmpty ? "Midterms" : parts.joined(separator: " ")
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        async let odds: Void = refreshOdds()
        async let results: Void = refreshVotes()
        _ = await (odds, results)
        lastUpdated = Date()
        for r in races.values.flatMap({ $0 }) where expandedRaces.contains(r.id) {
            await loadHistory(r)
        }
    }

    // MARK: Polymarket

    private func refreshOdds() async {
        do {
            var events: [APIEvent] = []
            // Include closed events so called races stay visible; the date floor keeps out old cycles.
            for offset in stride(from: 0, to: 500, by: 100) {
                let page = try await fetchEvents(offset: offset)
                events += page
                if page.count < 100 { break }
            }
            var grouped: [Category: [Race]] = [:]
            var seen = Set<String>()
            for e in events where !seen.contains(e.slug) {
                seen.insert(e.slug)
                guard let cat = Category.of(e) else { continue }
                let outcomes = (e.markets ?? []).compactMap { m -> Outcome? in
                    guard let p = m.yesPrice, let name = m.groupItemTitle, !name.isEmpty else { return nil }
                    if p <= 0, m.closed != true { return nil }  // placeholder slots ("Person A")
                    return Outcome(id: m.id, name: name, price: p, change24h: m.oneDayPriceChange,
                                   token: m.yesToken, image: m.image.flatMap(URL.init(string:)))
                }.sorted { $0.price > $1.price }
                guard !outcomes.isEmpty else { continue }
                grouped[cat, default: []].append(Race(
                    id: e.id, slug: e.slug, title: e.title.trimmingCharacters(in: .whitespaces), category: cat,
                    volume: e.volume ?? 0, closed: e.closed ?? false, outcomes: outcomes))
            }
            grouped[.headline]?.sort {
                (headlineSlugs.firstIndex(of: $0.slug) ?? 99) < (headlineSlugs.firstIndex(of: $1.slug) ?? 99)
            }
            for c in [Category.senate, .governor, .house] { grouped[c]?.sort { $0.volume > $1.volume } }
            races = grouped
            error = nil
            checkOddsAlerts()
        } catch {
            self.error = "Polymarket: \(error.localizedDescription)"
        }
    }

    private func fetchEvents(offset: Int) async throws -> [APIEvent] {
        var c = URLComponents(string: "https://gamma-api.polymarket.com/events")!
        c.queryItems = [
            .init(name: "tag_slug", value: "midterms"),
            .init(name: "end_date_min", value: "2026-11-01T00:00:00Z"),
            .init(name: "order", value: "volume"),
            .init(name: "ascending", value: "false"),
            .init(name: "limit", value: "100"),
            .init(name: "offset", value: String(offset)),
        ]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([APIEvent].self, from: data)
    }

    func loadHistory(_ r: Race) async {
        for o in r.outcomes.prefix(2) {
            guard let token = o.token else { continue }
            var c = URLComponents(string: "https://clob.polymarket.com/prices-history")!
            c.queryItems = [
                .init(name: "market", value: token),
                .init(name: "interval", value: "1d"),
                .init(name: "fidelity", value: "5"),
            ]
            struct Resp: Decodable { let history: [PricePoint] }
            guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
                  let resp = try? JSONDecoder().decode(Resp.self, from: data) else { continue }
            priceHistory[token] = resp.history
        }
    }

    // MARK: NYT results

    private func refreshVotes() async {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        var newVotes = votes
        for file in ["senate", "governor"] {
            var req = URLRequest(url: URL(string:
                "https://static01.nyt.com/elections-assets/pages/data/\(electionDate)/results-\(file).json")!)
            req.setValue("Mozilla/5.0 (Macintosh) MidtermsWatcher", forHTTPHeaderField: "User-Agent")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let f = try? dec.decode(NYTFile.self, from: data) else { continue }
            for r in f.races where r.officeId == "S" || r.officeId == "G" {
                let key = "\(r.topReportingUnit.statePostal)-\(r.officeId)"
                newVotes[key] = Self.result(from: r)
            }
            // The governor file carries both House and Senate tallies.
            if let offices = f.partyControlData?.results.first?.offices {
                for (k, o) in offices { if let t = Self.tally(o) { seats[k] = t } }
            }
        }
        votes = newVotes
        recordSnapshots()
        checkCallAlerts()
        firstVoteLoad = false
    }

    private static func result(from r: NYTRace) -> VoteResult {
        let u = r.topReportingUnit
        let total = u.totalVotes ?? 0
        let won = Set(r.outcome?.won ?? [])
        let cands = u.candidates.map { c -> VoteCandidate in
            let m = r.candidateMetadata[c.nytId]
            let last = m?.lastName ?? c.nytId
            let v = c.votes?.total ?? 0
            return VoteCandidate(
                id: c.nytId, name: last,
                fullName: [m?.firstName, m?.lastName].compactMap { $0 }.joined(separator: " "),
                party: Party(nyt: m?.party?.nytId), votes: v,
                share: total > 0 ? v / total : 0, won: won.contains(c.nytId))
        }.sorted { $0.votes > $1.votes }
        return VoteResult(eevp: u.eevp ?? 0, totalVotes: total, candidates: cands)
    }

    private static func tally(_ o: NYTOffice) -> SeatTally? {
        guard let b = o.partyBalance, let total = o.total else { return nil }
        let winner: Party? = b["DEM"]?.winner == true ? .dem : b["GOP"]?.winner == true ? .rep : nil
        return SeatTally(dem: b["DEM"]?.seats ?? 0, rep: b["GOP"]?.seats ?? 0, total: total,
                         toWin: o.toWin?["DEM"] ?? total / 2 + 1, called: o.numRacesCalled ?? 0, winner: winner)
    }

    /// Append a snapshot per race whenever its count moves, and persist the day's timeline.
    private func recordSnapshots() {
        var changed = false
        for (key, v) in votes where v.hasVotes {
            if let last = voteHistory[key]?.last, last.eevp == v.eevp,
               last.shares == Dictionary(uniqueKeysWithValues: v.candidates.map { ($0.id, $0.share) }) { continue }
            voteHistory[key, default: []].append(VoteSnapshot(
                t: Date(), eevp: v.eevp,
                shares: Dictionary(uniqueKeysWithValues: v.candidates.map { ($0.id, $0.share) })))
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(voteHistory) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    // MARK: Alerts

    private func checkOddsAlerts() {
        for r in races.values.flatMap({ $0 }) {
            guard let l = r.leader else { continue }
            guard let b = baseline[r.id] else {
                baseline[r.id] = (l.name, l.price, r.closed)
                continue
            }
            var msg: String?
            if r.closed && !b.closed {
                msg = "Market resolved: \(l.name)"
            } else if l.name != b.name {
                msg = "New favorite: \(l.name) \(pct(l.price)) (was \(b.name) \(pct(b.price)))"
            } else if abs(l.price - b.price) >= alertThreshold {
                msg = "\(l.name) \(l.price > b.price ? "▲" : "▼") \(pct(b.price)) → \(pct(l.price))"
            }
            if let msg {
                baseline[r.id] = (l.name, l.price, r.closed)
                notify(title: r.shortTitle, body: msg, url: r.url)
            }
        }
    }

    private func checkCallAlerts() {
        for (key, v) in votes {
            guard let w = v.winner, !announcedCalls.contains(key) else { continue }
            announcedCalls.insert(key)
            if firstVoteLoad { continue }  // don't replay calls made before launch
            let race = races.values.flatMap { $0 }.first { $0.voteKey == key }
            notify(title: "AP call: \(race?.shortTitle ?? key)",
                   body: "\(w.fullName) (\(w.party.letter)) wins — \(String(format: "%.1f", w.share * 100))%",
                   url: race?.url ?? URL(string: "https://www.nytimes.com/interactive/2026/11/03/us/elections/results.html")!)
        }
    }

    private func notify(title: String, body: String, url: URL) {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

func pct(_ p: Double) -> String {
    p < 0.01 && p > 0 ? "<1%" : "\(Int((p * 100).rounded()))%"
}

func volumeString(_ v: Double) -> String {
    if v >= 1_000_000 { return String(format: "$%.1fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "$%.0fK", v / 1_000) }
    return String(format: "$%.0f", v)
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var collapsed: Set<Category> = [.house]
    @State private var showAll: Set<Category> = []
    // Debug: MIDTERMS_SELECT=<event slug> starts with that race selected.
    @State private var selectedSlug: String? = ProcessInfo.processInfo.environment["MIDTERMS_SELECT"]
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var allRaces: [Race] { Category.allCases.flatMap { store.races[$0] ?? [] } }

    var selected: Race? {
        allRaces.first { $0.slug == selectedSlug } ?? store.races[.senate]?.first ?? allRaces.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Category.allCases, id: \.self) { cat in
                            if let list = store.races[cat], !list.isEmpty { section(cat, list) }
                        }
                        if store.races.isEmpty {
                            Text(store.error ?? "Loading…").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(30)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 420)
                Divider()
                if let r = selected {
                    RaceDetail(store: store, race: r).id(r.id)
                } else {
                    Spacer()
                }
            }
            .frame(height: 600)
            Divider()
            footer
        }
        .frame(width: 940)
        .onChange(of: selected?.id, initial: true) { _, _ in
            guard let r = selected else { return }
            store.expandedRaces = [r.id]
            Task { await store.loadHistory(r) }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.gold)
                    Text("2026 Midterms").font(.system(.title3, design: .rounded).weight(.bold))
                }
                HStack(spacing: 6) {
                    Text("LIVE").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.red, in: Capsule())
                    if store.loading { ProgressView().controlSize(.mini) }
                }
                Text(Date().formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            if let h = store.race(headlineSlugs[0]) {
                ChamberCard(label: "House", icon: "house.fill", race: h, seats: store.seats["H"])
            }
            if let s = store.race(headlineSlugs[1]) {
                ChamberCard(label: "Senate", icon: "building.columns.fill", race: s, seats: store.seats["S"])
            }
            if let b = store.race(headlineSlugs[2]) { BalanceCard(race: b) }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Theme.blue.opacity(0.18), Theme.purple.opacity(0.10), Theme.red.opacity(0.18)],
                           startPoint: .leading, endPoint: .trailing))
    }

    func section(_ cat: Category, _ list: [Race]) -> some View {
        let isOpen = !collapsed.contains(cat)
        let visible = showAll.contains(cat) ? list : Array(list.prefix(collapsedRaceCount))
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { if isOpen { collapsed.insert(cat) } else { collapsed.remove(cat) } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cat.icon).foregroundStyle(cat.tint).frame(width: 16)
                    Text(cat.rawValue).font(.system(.subheadline, design: .rounded).weight(.bold))
                    Text("\(list.count)").font(.caption2.bold()).foregroundStyle(cat.tint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(cat.tint.opacity(0.15), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(visible) { r in
                    RaceRow(store: store, race: r, selected: r.id == selected?.id) { selectedSlug = r.slug }
                }
                if list.count > collapsedRaceCount {
                    Button(showAll.contains(cat) ? "Show fewer" : "Show all \(list.count)") {
                        if showAll.contains(cat) { showAll.remove(cat) } else { showAll.insert(cat) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            if let e = store.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
            }
            if let t = store.lastUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Odds: Polymarket · Votes: AP via NYT · refreshes every \(Int(refreshInterval))s")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Toggle(isOn: $openAtLogin) { Label("Open at login", systemImage: "power.circle") }
                .toggleStyle(.button).controlSize(.small)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle(isOn: $store.alertsEnabled) {
                Label("Alerts", systemImage: store.alertsEnabled ? "bell.fill" : "bell.slash")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Notify on \(Int(alertThreshold * 100))-pt odds moves, favorite changes, and AP calls")
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .controlSize(.small).disabled(store.loading).help("Refresh now")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .controlSize(.small).help("Quit")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Polymarket names don't always carry "(D)"/"(R)"; fall back to the NYT candidate's party.
func party(of o: Outcome, votes: VoteResult?) -> Party {
    o.party != .other ? o.party : votes?.candidates.first { $0.name == o.lastName }?.party ?? .other
}

struct BalanceCard: View {
    let race: Race

    var body: some View {
        Button { NSWorkspace.shared.open(race.url) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("BALANCE OF POWER", systemImage: "scale.3d")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                ForEach(race.outcomes.prefix(3)) { o in
                    HStack(spacing: 4) {
                        Text(o.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(pct(o.price)).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(o.party.color)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct ChamberCard: View {
    let label: String
    let icon: String
    let race: Race
    let seats: SeatTally?

    var body: some View {
        Button { NSWorkspace.shared.open(race.url) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(label.uppercased(), systemImage: icon)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                if let l = race.leader {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(l.party.letter) \(pct(l.price))")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(l.party.color)
                        ChangeBadge(change: l.change24h)
                    }
                    OddsBar(dem: race.outcomes.first { $0.party == .dem }?.price ?? 0,
                            rep: race.outcomes.first { $0.party == .rep }?.price ?? 0)
                        .frame(height: 5)
                }
                if let s = seats {
                    HStack(spacing: 4) {
                        Text("D \(s.dem)").foregroundStyle(Theme.blue)
                        Text("·").foregroundStyle(.tertiary)
                        Text("R \(s.rep)").foregroundStyle(Theme.red)
                        Text("seats · \(s.toWin) to win").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct OddsBar: View {
    let dem: Double
    let rep: Double
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                Theme.blue.frame(width: g.size.width * dem / max(dem + rep, 0.0001))
                Theme.red
            }
            .clipShape(Capsule())
        }
    }
}

struct Avatar: View {
    let url: URL?
    let party: Party
    var size: CGFloat = 20

    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Text(party.letter).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(party.color)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(party.color, lineWidth: 1.5))
    }
}

struct ChangeBadge: View {
    let change: Double?
    var body: some View {
        if let c = change, abs(c) >= 0.005 {
            HStack(spacing: 1) {
                Image(systemName: c > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 6))
                Text("\(Int((abs(c) * 100).rounded()))")
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(c > 0 ? Theme.up : Theme.down)
            .help("24h change (pts)")
        }
    }
}

struct RaceRow: View {
    @ObservedObject var store: Store
    let race: Race
    let selected: Bool
    let onSelect: () -> Void

    var votes: VoteResult? { race.voteKey.flatMap { store.votes[$0] } }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                titleLine
                ForEach(race.outcomes.prefix(race.category == .headline ? 5 : 2)) { o in
                    OutcomeLine(outcome: o, party: party(of: o, votes: votes))
                }
                if let v = votes, v.hasVotes { voteSummary(v) }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? race.category.tint.opacity(0.14) : Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? race.category.tint.opacity(0.7) : .clear, lineWidth: 1.5))
        .overlay(alignment: .leading) {
            if let l = race.leader {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(party(of: l, votes: votes).color.opacity(0.8)).frame(width: 3)
            }
        }
    }

    var titleLine: some View {
        HStack(spacing: 6) {
            Text(race.shortTitle).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1)
            CallBadge(race: race, votes: votes)
            Spacer()
            Text(volumeString(race.volume)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                .foregroundStyle(selected ? race.category.tint : Color.secondary.opacity(0.5))
        }
    }

    func voteSummary(_ v: VoteResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "envelope.badge.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 18)
            Text("\(Int(v.eevp))% in").font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            ForEach(v.candidates.prefix(2)) { c in
                HStack(spacing: 2) {
                    Circle().fill(c.party.color).frame(width: 6, height: 6)
                    Text("\(c.name) \(String(format: "%.1f", c.share * 100))%")
                }
                .font(.system(size: 10, weight: c.id == v.candidates.first?.id ? .bold : .regular).monospacedDigit())
            }
            Spacer()
        }
    }
}

struct CallBadge: View {
    let race: Race
    let votes: VoteResult?

    var body: some View {
        if let w = votes?.winner {
            Label("AP: \(w.name)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(w.party.color, in: Capsule())
        } else if race.closed {
            Label("RESOLVED", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.up)
        }
    }
}

struct OutcomeLine: View {
    let outcome: Outcome
    let party: Party
    var avatarSize: CGFloat = 18
    var nameWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: outcome.image, party: party, size: avatarSize)
            Text(outcome.name).font(avatarSize > 20 ? .callout : .caption).lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [party.color.opacity(0.65), party.color],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, g.size.width * outcome.price))
                }
            }
            .frame(height: avatarSize > 20 ? 9 : 7)
            Text(pct(outcome.price))
                .font(.system(size: avatarSize > 20 ? 14 : 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(party.color).frame(width: 40, alignment: .trailing)
            ChangeBadge(change: outcome.change24h).frame(width: 26, alignment: .trailing)
        }
    }
}

struct RaceDetail: View {
    @ObservedObject var store: Store
    let race: Race

    var votes: VoteResult? { race.voteKey.flatMap { store.votes[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: race.category.icon).font(.title2).foregroundStyle(race.category.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(race.shortTitle).font(.system(.title2, design: .rounded).weight(.bold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(volumeString(race.volume)) traded").font(.caption).foregroundStyle(.secondary)
                            CallBadge(race: race, votes: votes)
                        }
                    }
                    Spacer()
                    Button { NSWorkspace.shared.open(race.url) } label: {
                        Label("Polymarket", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }

                card {
                    DetailHeader(title: "Polymarket odds", icon: "chart.bar.fill")
                    ForEach(race.outcomes.prefix(6)) { o in
                        OutcomeLine(outcome: o, party: party(of: o, votes: votes), avatarSize: 26, nameWidth: 170)
                    }
                    DetailHeader(title: "Today", icon: "chart.line.uptrend.xyaxis").padding(.top, 6)
                    OddsChart(store: store, outcomes: Array(race.outcomes.prefix(2)),
                              colors: race.outcomes.prefix(2).map { party(of: $0, votes: votes).color })
                        .frame(height: 140)
                }

                if let key = race.voteKey {
                    card {
                        if let v = votes, v.hasVotes {
                            DetailHeader(title: "Vote count", icon: "envelope.open.fill")
                            VoteTable(result: v)
                            if let h = store.voteHistory[key], h.count >= 2 {
                                DetailHeader(title: "Vote share over time", icon: "clock.arrow.circlepath")
                                    .padding(.top, 6)
                                VoteShareChart(history: h, candidates: Array(v.candidates.prefix(2)))
                                    .frame(height: 140)
                            } else {
                                Text("Vote-share timeline fills in as new counts arrive.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            DetailHeader(title: "Vote count", icon: "envelope.open.fill")
                            Label("No votes counted yet: polls haven't closed or nothing has been reported.",
                                  systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DetailHeader: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title.uppercased(), systemImage: icon)
            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
    }
}

struct VoteTable: View {
    let result: VoteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView(value: min(result.eevp, 100), total: 100).tint(Theme.gold)
                Text("\(Int(result.eevp))% of expected vote").font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary).fixedSize()
            }
            ForEach(result.candidates.prefix(4)) { c in
                HStack(spacing: 6) {
                    Text(c.party.letter).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(c.party.color, in: RoundedRectangle(cornerRadius: 4))
                    Text(c.fullName).font(.caption).lineLimit(1).frame(width: 120, alignment: .leading)
                    if c.won { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.up) }
                    Spacer()
                    Text(c.votes.formatted(.number)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", c.share * 100))
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(c.party.color).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

struct OddsChart: View {
    @ObservedObject var store: Store
    let outcomes: [Outcome]
    let colors: [Color]

    var body: some View {
        let series = outcomes.compactMap { o in o.token.flatMap { store.priceHistory[$0] }.map { (o, $0) } }
        if series.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(series, id: \.0.id) { o, pts in
                    ForEach(pts, id: \.t) { pt in
                        LineMark(x: .value("Time", pt.date), y: .value("Odds", pt.p))
                            .foregroundStyle(by: .value("Outcome", o.name))
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartForegroundStyleScale(domain: series.map(\.0.name), range: Array(colors.prefix(series.count)))
            .chartYScale(domain: 0...1)
            .chartYAxis { percentAxis }
            .chartXAxis { hourAxis }
            .chartLegend(.hidden)
        }
    }
}

struct VoteShareChart: View {
    let history: [VoteSnapshot]
    let candidates: [VoteCandidate]

    var body: some View {
        Chart {
            ForEach(candidates) { c in
                ForEach(history, id: \.t) { s in
                    if let share = s.shares[c.id] {
                        LineMark(x: .value("Time", s.t), y: .value("Share", share), series: .value("Who", c.name))
                            .foregroundStyle(c.party.color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            ForEach(history, id: \.t) { s in
                LineMark(x: .value("Time", s.t), y: .value("Share", s.eevp / 100), series: .value("Who", "% in"))
                    .foregroundStyle(Theme.gold.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis { percentAxis }
        .chartXAxis { hourAxis }
        .overlay(alignment: .topLeading) {
            Text("- - % counted").font(.system(size: 8)).foregroundStyle(Theme.gold).padding(.leading, 4)
        }
    }
}

var percentAxis: some AxisContent {
    AxisMarks(position: .trailing, values: [0, 0.25, 0.5, 0.75, 1]) { v in
        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
        AxisValueLabel { Text("\(Int((v.as(Double.self) ?? 0) * 100))%").font(.system(size: 8)) }
    }
}

var hourAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
        AxisValueLabel(format: .dateTime.hour()).font(.system(size: 8))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if CommandLine.arguments.contains("--window") {
            MainActor.assumeIsolated {
                let w = NSWindow(contentViewController: NSHostingController(rootView: ContentView(store: .shared)))
                w.title = "Midterms Watcher"
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                debugWindow = w
                print("window-id \(w.windowNumber)")
                fflush(stdout)
            }
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let s = r.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
        done()
    }
}

@main
struct MidtermsWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "building.columns.fill")
                Text(store.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
