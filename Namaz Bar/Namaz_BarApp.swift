//
//  Namaz_BarApp.swift
//  Namaz Bar
//
//  Created by Miqdad Somji on 10/03/2026.
//

import SwiftUI
import AppKit
import Foundation
import UserNotifications
import ServiceManagement
import Combine

struct PrayerAPIResponse: Codable {
    let fajr: String
    let sunrise: String
    let zohr: String
    let maghrib: String
    let imsaak: String
    let sunset: String
}

struct PrayerMoment: Equatable {
    let name: String
    let date: Date
    let displayTime: String
}

enum CityOption: String, CaseIterable, Identifiable {
    case birmingham
    case leicester
    case london
    case peterborough

    var id: String { rawValue }

    var title: String {
        switch self {
        case .birmingham: return "Birmingham"
        case .leicester: return "Leicester"
        case .london: return "London"
        case .peterborough: return "Peterborough"
        }
    }
}

enum NotificationLead: Int, CaseIterable, Identifiable {
    case off = 0
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .five: return "5 min"
        case .ten: return "10 min"
        case .fifteen: return "15 min"
        }
    }
}

final class APIClient {
    func fetchPrayerTimes(city: String, date: Date) async throws -> PrayerAPIResponse {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = String(format: "%02d", calendar.component(.month, from: date))
        let day = String(format: "%02d", calendar.component(.day, from: date))

        let urlString = "https://api.poc.hujjat.org/salaat/city/\(city.lowercased())/year/\(year)/month/\(month)/day/\(day)"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        print("Fetching URL:", url.absoluteString)

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(PrayerAPIResponse.self, from: data)
    }
}

@main
struct Namaz_BarApp: App {
    @State private var selectedCity: CityOption
    @State private var notificationLead: NotificationLead
    @State private var isLoading = false
    @State private var statusText = "Not loaded"
    @State private var now = Date()
    @State private var todayResponse: PrayerAPIResponse?
    @State private var tomorrowResponse: PrayerAPIResponse?
    @State private var lastFetchedDayKey = ""
    @State private var lastScheduledNotificationKey = ""
    @State private var launchAtLoginEnabled: Bool

    private let api = APIClient()
    private let secondTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    init() {
        let savedCity = UserDefaults.standard.string(forKey: "selectedCity")
        let savedLead = UserDefaults.standard.integer(forKey: "notificationLeadMinutes")

        _selectedCity = State(initialValue: CityOption(rawValue: savedCity ?? "") ?? .london)
        _notificationLead = State(initialValue: NotificationLead(rawValue: savedLead) ?? .off)
        _launchAtLoginEnabled = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some Scene {
        MenuBarExtra(menuBarTitle) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Namaz Bar")
                    .font(.headline)

                Divider()

                Text("Next: \(nextPrayerDisplay)")
                Text("Countdown: \(countdownDisplay)")
                Text("Status: \(statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Menu("City") {
                    ForEach(CityOption.allCases) { city in
                        Button(cityMenuTitle(for: city)) {
                            changeCity(to: city)
                        }
                    }
                }

                Menu("Notifications") {
                    ForEach(NotificationLead.allCases) { lead in
                        Button(notificationMenuTitle(for: lead)) {
                            setNotificationLead(lead)
                        }
                    }
                }

                Button(launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                    toggleLaunchAtLogin()
                }

                Divider()

                Menu("Today") {
                    Button("Imsaak: \(todayResponse?.imsaak ?? "--")") {}
                        .disabled(true)
                    Button("Fajr: \(todayResponse?.fajr ?? "--")") {}
                        .disabled(true)
                    Button("Sunrise: \(todayResponse?.sunrise ?? "--")") {}
                        .disabled(true)
                    Button("Zohr: \(todayResponse?.zohr ?? "--")") {}
                        .disabled(true)
                    Button("Sunset: \(todayResponse?.sunset ?? "--")") {}
                        .disabled(true)
                    Button("Maghrib: \(todayResponse?.maghrib ?? "--")") {}
                        .disabled(true)
                }

                Menu("Tomorrow") {
                    Button("Imsaak: \(tomorrowResponse?.imsaak ?? "--")") {}
                        .disabled(true)
                    Button("Fajr: \(tomorrowResponse?.fajr ?? "--")") {}
                        .disabled(true)
                    Button("Sunrise: \(tomorrowResponse?.sunrise ?? "--")") {}
                        .disabled(true)
                    Button("Zohr: \(tomorrowResponse?.zohr ?? "--")") {}
                        .disabled(true)
                    Button("Sunset: \(tomorrowResponse?.sunset ?? "--")") {}
                        .disabled(true)
                    Button("Maghrib: \(tomorrowResponse?.maghrib ?? "--")") {}
                        .disabled(true)
                }
                
                Divider()

                Button(isLoading ? "Refreshing..." : "Refresh Now") {
                    Task {
                        await refreshPrayerTimes(forceNetwork: true)
                    }
                }
                .disabled(isLoading)

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
            .task {
                await refreshPrayerTimes(forceNetwork: true)
            }
            .onReceive(secondTimer) { _ in
                handleSecondTick()
            }
        }
    }

    // MARK: - Derived UI

    private var menuBarTitle: String {
        guard let next = computedNextPrayer() else {
            return "Hujjat Namaz"
        }

        let countdown = formatCountdown(from: now, to: next.date)
        return "\(next.name) \(next.displayTime) · \(countdown)"
    }

    private var nextPrayerDisplay: String {
        guard let next = computedNextPrayer() else { return "--" }
        return "\(next.name) \(next.displayTime)"
    }

    private var countdownDisplay: String {
        guard let next = computedNextPrayer() else { return "--" }
        return formatCountdown(from: now, to: next.date)
    }

    @ViewBuilder
    private func timetableRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .frame(minWidth: 220)
    }

    private func cityMenuTitle(for city: CityOption) -> String {
        city == selectedCity ? "✓ \(city.title)" : city.title
    }

    private func notificationMenuTitle(for lead: NotificationLead) -> String {
        lead == notificationLead ? "✓ \(lead.title)" : lead.title
    }

    // MARK: - Timer + Refresh

    private func handleSecondTick() {
        now = Date()

        let todayKey = dateKey(for: now)

        // refresh automatically when the day rolls over
        if todayKey != lastFetchedDayKey && !isLoading {
            Task {
                await refreshPrayerTimes(forceNetwork: true)
            }
        }

        scheduleNextPrayerNotificationIfNeeded()
    }

    private func changeCity(to city: CityOption) {
        selectedCity = city
        UserDefaults.standard.set(city.rawValue, forKey: "selectedCity")

        Task {
            await refreshPrayerTimes(forceNetwork: true)
        }
    }

    private func setNotificationLead(_ lead: NotificationLead) {
        notificationLead = lead
        UserDefaults.standard.set(lead.rawValue, forKey: "notificationLeadMinutes")

        Task {
            await requestNotificationPermissionIfNeeded()
            scheduleNextPrayerNotificationIfNeeded(force: true)
        }
    }

    private func refreshPrayerTimes(forceNetwork: Bool) async {
        isLoading = true
        statusText = "Fetching \(selectedCity.title) timetable..."

        let calendar = Calendar.current
        let today = now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let todayKey = dateKey(for: today)
        let tomorrowKey = dateKey(for: tomorrow)

        do {
            async let todayFetch = api.fetchPrayerTimes(city: selectedCity.rawValue, date: today)
            async let tomorrowFetch = api.fetchPrayerTimes(city: selectedCity.rawValue, date: tomorrow)

            let fetchedToday = try await todayFetch
            let fetchedTomorrow = try await tomorrowFetch

            todayResponse = fetchedToday
            tomorrowResponse = fetchedTomorrow
            lastFetchedDayKey = todayKey
            statusText = "Live data · \(selectedCity.title)"

            saveCache(fetchedToday, city: selectedCity.rawValue, dateKey: todayKey)
            saveCache(fetchedTomorrow, city: selectedCity.rawValue, dateKey: tomorrowKey)

            print("Prayer API connected successfully:", fetchedToday)
            scheduleNextPrayerNotificationIfNeeded(force: true)
        } catch {
            let cachedToday = loadCache(city: selectedCity.rawValue, dateKey: todayKey)
            let cachedTomorrow = loadCache(city: selectedCity.rawValue, dateKey: tomorrowKey)

            if let cachedToday, let cachedTomorrow {
                todayResponse = cachedToday
                tomorrowResponse = cachedTomorrow
                lastFetchedDayKey = todayKey
                statusText = "Offline fallback · \(selectedCity.title)"
            } else {
                let nsError = error as NSError
                statusText = "\(nsError.domain) (\(nsError.code))"
                print("Prayer API error:", error)
                print("NSError domain:", nsError.domain)
                print("NSError code:", nsError.code)
                print("NSError userInfo:", nsError.userInfo)
            }
        }

        isLoading = false
    }

    // MARK: - Prayer Logic

    private func prayerMoments(from response: PrayerAPIResponse, on date: Date) -> [PrayerMoment] {
        let tracked = [
            ("Fajr", response.fajr),
            ("Zohr", response.zohr),
            ("Maghrib", response.maghrib)
        ]

        return tracked.compactMap { name, timeString in
            guard let dateValue = makeDate(from: timeString, on: date) else { return nil }
            return PrayerMoment(name: name, date: dateValue, displayTime: timeString)
        }
    }

    private func computedNextPrayer() -> PrayerMoment? {
        guard let todayResponse else { return nil }

        let todayMoments = prayerMoments(from: todayResponse, on: now)

        if let nextToday = todayMoments.first(where: { $0.date > now }) {
            return nextToday
        }

        guard let tomorrowResponse else { return nil }
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowMoments = prayerMoments(from: tomorrowResponse, on: tomorrowDate)

        return tomorrowMoments.first(where: { $0.name == "Fajr" })
    }

    private func makeDate(from timeString: String, on baseDate: Date) -> Date? {
        let parts = timeString.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        let calendar = Calendar.current
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
    }

    private func formatCountdown(from now: Date, to futureDate: Date) -> String {
        let seconds = max(0, Int(futureDate.timeIntervalSince(now)))

        if seconds < 60 {
            return "Now"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Cache

    private func saveCache(_ response: PrayerAPIResponse, city: String, dateKey: String) {
        let key = "prayerCache.\(city).\(dateKey)"
        if let data = try? JSONEncoder().encode(response) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadCache(city: String, dateKey: String) -> PrayerAPIResponse? {
        let key = "prayerCache.\(city).\(dateKey)"
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PrayerAPIResponse.self, from: data)
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() async {
        guard notificationLead != .off else { return }

        do {
            let center = UNUserNotificationCenter.current()
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            print("Notification permission error:", error)
        }
    }

    private func scheduleNextPrayerNotificationIfNeeded(force: Bool = false) {
        guard notificationLead != .off else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nextPrayerReminder"])
            lastScheduledNotificationKey = ""
            return
        }

        guard let next = computedNextPrayer() else { return }

        let fireDate = next.date.addingTimeInterval(TimeInterval(-notificationLead.rawValue * 60))
        guard fireDate > now else { return }

        let key = "\(next.name)-\(next.displayTime)-\(notificationLead.rawValue)"

        if !force && key == lastScheduledNotificationKey {
            return
        }

        lastScheduledNotificationKey = key

        let content = UNMutableNotificationContent()
        content.title = "\(next.name) coming up"
        content.body = "\(next.name) is at \(next.displayTime) in \(selectedCity.title)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: fireDate.timeIntervalSince(now),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "nextPrayerReminder",
            content: content,
            trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["nextPrayerReminder"])
        center.add(request)
    }

    // MARK: - Login Item

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginEnabled = false
                statusText = "Launch at login disabled"
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginEnabled = true
                statusText = "Launch at login enabled"
            }
        } catch {
            let nsError = error as NSError
            statusText = "Login item error \(nsError.code)"
            print("Launch at login error:", error)
        }
    }
}

