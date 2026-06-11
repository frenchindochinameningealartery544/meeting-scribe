import Foundation
import EventKit

/// Watches the user's calendar and fires an OS notification when a meeting
/// that carries a video-conference link (Meet / Zoom / Teams / Whereby / …) is
/// about to start. This complements `MeetingDetector` (which only sees
/// browser tabs) so reminders also work for native Teams/Zoom apps and for
/// meetings you haven't opened yet.
final class CalendarMonitor {

    static let shared = CalendarMonitor()

    private let store = EKEventStore()
    private var timer: Timer?
    private var notifiedEventIDs = Set<String>()

    /// Hosts that mark an event as a video meeting worth recording.
    private let meetingHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "whereby.com", "meet.jit.si", "gather.town", "app.gather.town",
        "around.co", "webex.com", "meet.around.co"
    ]

    /// Request calendar access, then poll on a timer.
    func start() {
        let onGrant: (Bool, Error?) -> Void = { [weak self] granted, error in
            if let error {
                NSLog("[CalendarMonitor] access error: \(error.localizedDescription)")
            }
            guard granted else {
                NSLog("[CalendarMonitor] calendar access denied")
                return
            }
            DispatchQueue.main.async { self?.beginPolling() }
        }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: onGrant)
        } else {
            store.requestAccess(to: .event, completion: onGrant)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func beginPolling() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let now = Date()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return }

        // Look at events from 1 min ago to 15 min ahead, fire ~90s before start.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(15 * 60),
            calendars: calendars
        )
        let fireWindowEnd = now.addingTimeInterval(90)

        for event in store.events(matching: predicate) {
            guard let id = event.eventIdentifier, !notifiedEventIDs.contains(id) else { continue }
            let start: Date = event.startDate
            // Only notify around the start moment: [now-60s, now+90s].
            guard start >= now.addingTimeInterval(-60), start <= fireWindowEnd else { continue }
            guard let link = meetingLink(in: event) else { continue }

            notifiedEventIDs.insert(id)
            let title = event.title ?? "Зустріч"
            NotificationManager.shared.notifyMeetingStarting(
                title: "🎙 Кол починається",
                body: "«\(title)» — натисни «Почати запис»",
                meetingURL: link
            )
        }

        // Keep the dedupe set from growing unbounded across a long session.
        if notifiedEventIDs.count > 500 { notifiedEventIDs.removeAll() }
    }

    /// Returns the first video-meeting URL found in the event's url/location/notes.
    private func meetingLink(in event: EKEvent) -> String? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for field in fields {
            let lower = field.lowercased()
            guard meetingHosts.contains(where: { lower.contains($0) }) else { continue }
            if let extracted = firstURL(in: field, matchingHosts: meetingHosts) {
                return extracted
            }
            return field
        }
        return nil
    }

    /// Scan a blob of text for the first http(s) token whose host is a known meeting host.
    private func firstURL(in text: String, matchingHosts hosts: [String]) -> String? {
        let tokens = text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "<" || $0 == ">" || $0 == "\"" }
        for token in tokens {
            let s = String(token)
            let lower = s.lowercased()
            guard lower.hasPrefix("http"), hosts.contains(where: { lower.contains($0) }) else { continue }
            return s
        }
        return nil
    }
}
