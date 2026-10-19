// Today's meetings from macOS Calendar (EventKit, read-only), and the reminders
// that go with them. Published to the pages as data "calendar"; reminders are
// scheduled natively so they fire on time even if no page is open. The past week's
// meetings go to the cache (calendar-past.json) for the standup write-up.
// Config `calendar.only` (calendar or account names) limits it to your work calendar;
// `lastChange`, the newest edit macOS has from those calendars, tells the page when
// an account has stopped syncing (macOS keeps showing the old copy without a word).

import Cocoa
import EventKit
import UserNotifications

final class Agenda {
  static let shared = Agenda()
  private let store = EKEventStore()
  private var timer: Timer?
  private let iso = ISO8601DateFormatter()
  private let meetRe = try! NSRegularExpression(pattern: #"https://(meet\.google\.com/[a-z\-]+|[\w.]*zoom\.us/j/[^\s<>"]+|teams\.(microsoft|live)\.com/[^\s<>"]+|[\w.]*webex\.com/[^\s<>"]+|app\.slack\.com/huddle/[^\s<>"]+|whereby\.com/[^\s<>"]+)"#)
  private var lastJSON = ""

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    timer?.tolerance = 10   // calendar edits arrive by EKEventStoreChanged; this is the catch-all: let macOS batch it
    NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
    // a new reminder lead time or timezone must reschedule even when no event changed
    Store.shared.onChange.append { [weak self] kind, _ in if kind == "config" { self?.lastJSON = ""; self?.refresh() } }
  }

  func refresh() {
    store.requestFullAccessToEvents { [weak self] granted, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted else { Store.shared.setData("calendar", #"{"error":"no-access"}"#); return }
        self.publish()
      }
    }
  }

  private func publish() {
    // "today" is the configured timezone's day, like everywhere else in the app
    var cal = Calendar.current
    if let tz = (Store.shared.config["timezone"] as? String).flatMap(TimeZone.init(identifier:)) { cal.timeZone = tz }
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: 7, to: start)!      // a week: the meeting widget pages through it
    let cals = calendars()
    var obj: [String: Any] = ["calendars": cals.count]
    if cals.isEmpty, !only.isEmpty {
      obj["error"] = "No calendar named \(only.joined(separator: " or ")) in macOS Calendar"; obj["events"] = []
    } else {
      obj["events"] = eventList(from: start, to: end, in: cals)
      let past = (try? JSONSerialization.data(withJSONObject: ["events": eventList(from: cal.date(byAdding: .day, value: -7, to: start)!, to: start, in: cals, notes: true)]))
      try? past?.write(to: Paths.cache.appendingPathComponent("calendar-past.json"), options: .atomic)
      // a live work calendar changes every few days (new invites, moved meetings)
      let around = store.events(matching: store.predicateForEvents(withStart: cal.date(byAdding: .day, value: -30, to: start)!, end: cal.date(byAdding: .day, value: 30, to: start)!, calendars: cals))
      if let newest = around.compactMap(\.lastModifiedDate).max() { obj["lastChange"] = iso.string(from: newest) }
    }
    let events = obj["events"] as? [[String: Any]] ?? []
    let json = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"events":[]}"#
    guard json != lastJSON else { return }   // nothing changed: no redraw, no rescheduling
    lastJSON = json
    Store.shared.setData("calendar", json)
    Notifier.shared.scheduleMeetings(events)
  }

  /// config `calendar.only`: the calendar or account names to read (empty = every calendar)
  private var only: [String] { ((Store.shared.config["calendar"] as? [String: Any])?["only"] as? [String]) ?? [] }
  private func calendars() -> [EKCalendar] {
    let all = store.calendars(for: .event), names = only
    return names.isEmpty ? all : all.filter { names.contains($0.title) || names.contains($0.source.title) }
  }

  /// The meetings you haven't declined between two moments; with `notes`, the start of each
  /// invite's description too (what the meeting was about, for the standup).
  private func eventList(from start: Date, to end: Date, in cals: [EKCalendar], notes: Bool = false) -> [[String: Any]] {
    var events: [[String: Any]] = []
    for e in store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals)) {
      let me = e.attendees?.first(where: { $0.isCurrentUser })
      if me?.participantStatus == .declined { continue }
      // only a web link counts: an invite's URL field is set by whoever sent it
      var link = e.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil } ?? ""
      let hay = [e.location ?? "", e.notes ?? ""].joined(separator: "\n")
      if let m = meetRe.firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay)), let r = Range(m.range, in: hay) { link = String(hay[r]) }
      events.append([
        "id": e.calendarItemIdentifier,
        "title": e.title ?? "(no title)",
        "start": iso.string(from: e.startDate), "end": iso.string(from: e.endDate),
        "allDay": e.isAllDay, "calendar": e.calendar.title,
        "color": e.calendar.color.flatMap { $0.usingColorSpace(.sRGB) }.map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#7c84e8",
        "link": link,
        "attendees": e.attendees?.count ?? 0,
        "tentative": me?.participantStatus == .tentative || me?.participantStatus == .pending,
        "notes": notes ? String((e.notes ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(300)) : "",
      ])
    }
    return events
  }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()
  private let center = UNUserNotificationCenter.current()

  func start() {
    center.delegate = self
    let join = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
    let investigate = UNNotificationAction(identifier: "investigate", title: "Investigate in Claude", options: [.foreground])
    center.setNotificationCategories([UNNotificationCategory(identifier: "link", actions: [join], intentIdentifiers: []),
                                      UNNotificationCategory(identifier: "incident", actions: [investigate, join], intentIdentifiers: [])])
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private var notifyCfg: [String: Any] { Store.shared.config["notifications"] as? [String: Any] ?? [:] }

  /// One reminder per meeting, N minutes before (config notifications.meetingMinutesBefore).
  func scheduleMeetings(_ events: [[String: Any]]) {
    let lead = (notifyCfg["meetingMinutesBefore"] as? Double) ?? 5
    let iso = ISO8601DateFormatter()
    center.getPendingNotificationRequests { pending in
      let mine = pending.filter { $0.identifier.hasPrefix("meeting.") }.map(\.identifier)
      self.center.removePendingNotificationRequests(withIdentifiers: mine)
      guard lead > 0 else { return }   // reminders off: the old ones are gone too
      for e in events {
        guard e["allDay"] as? Bool != true, let s = e["start"] as? String, let start = iso.date(from: s),
              start.timeIntervalSinceNow < 48 * 3600 else { continue }   // two days ahead is plenty (macOS caps pending at 64)
        let fire = start.addingTimeInterval(-lead * 60)
        guard fire > Date() else { continue }
        let c = UNMutableNotificationContent()
        c.title = e["title"] as? String ?? "Meeting"
        c.body = "Starts in \(Int(lead)) minutes" + ((e["link"] as? String ?? "").isEmpty ? "" : " — click to join")
        c.sound = .default
        c.threadIdentifier = "meetings"
        if let link = e["link"] as? String, !link.isEmpty { c.userInfo = ["url": link]; c.categoryIdentifier = "link" }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        let req = UNNotificationRequest(identifier: "meeting.\(e["id"] as? String ?? s).\(s)", content: c,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        self.center.add(req)
      }
    }
  }

  /// An alert from the pages (system down, urgent issue, login expired) — once per id.
  func post(id: String, title: String, body: String, url: String?, investigate: String? = nil) {
    var seen = Store.shared.state["notified"] as? [String: Double] ?? [:]
    let now = Date().timeIntervalSince1970
    seen = seen.filter { now - $0.value < 7 * 86400 }          // forget after a week
    guard seen[id] == nil else { return }
    seen[id] = now
    Store.shared.setState("notified", seen)
    let c = UNMutableNotificationContent()
    c.title = title; c.body = body; c.sound = .default
    c.threadIdentifier = String(id.split(separator: ".").first ?? "alerts")   // grouped: systems, issues, logins…
    if let url, !url.isEmpty { c.userInfo = ["url": url]; c.categoryIdentifier = "link" }
    if let investigate, !investigate.isEmpty { c.userInfo["investigate"] = investigate; c.categoryIdentifier = "incident" }
    center.add(UNNotificationRequest(identifier: "alert.\(id)", content: c, trigger: nil))
  }

  /// Pages report which alerts are active now; one that ended is forgotten, so if
  /// it comes back (a second outage) you are told again.
  func keepOnly(_ active: [String]) {
    let seen = Store.shared.state["notified"] as? [String: Double] ?? [:]
    let kept = seen.filter { active.contains($0.key) }
    if kept.count != seen.count { Store.shared.setState("notified", kept) }
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                              withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done([.banner, .sound])
  }
  func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                              withCompletionHandler done: @escaping () -> Void) {
    let info = r.notification.request.content.userInfo
    if r.actionIdentifier == "investigate", let s = info["investigate"] as? String { Investigator.start(subject: s) }
    else if let s = info["url"] as? String, let u = safeURL(s) { NSWorkspace.shared.open(u) }
    done()
  }
}
