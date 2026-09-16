import Foundation

/// "Today, 3:29 PM · 22 min" for a meeting in a list.
enum MeetingTime {

    static func summary(_ meeting: Meeting, now: Date = Date()) -> String {
        "\(when(meeting.started, now: now)) · \(duration(meeting.duration))"
    }

    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))), \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}
