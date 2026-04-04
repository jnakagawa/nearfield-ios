import SwiftUI
import WidgetKit

struct TPAWaitEntry: TimelineEntry {
    let date: Date
    let fetchedAt: Date
    let waitMinutes: Int?
    let waitDescription: String
    let checkpointStatuses: [CheckpointStatus]
    let errorMessage: String?
}

struct CheckpointStatus: Hashable {
    let name: String
    let status: String
}

struct TPAWaitProvider: TimelineProvider {
    func placeholder(in context: Context) -> TPAWaitEntry {
        TPAWaitEntry(
            date: Date(),
            fetchedAt: Date(),
            waitMinutes: 18,
            waitDescription: "17 minutes and 30 seconds",
            checkpointStatuses: [
                CheckpointStatus(name: "A", status: "Open"),
                CheckpointStatus(name: "C", status: "Open"),
                CheckpointStatus(name: "E", status: "Open"),
                CheckpointStatus(name: "F", status: "Open"),
            ],
            errorMessage: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TPAWaitEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TPAWaitEntry>) -> Void) {
        Task {
            let entry = await TPAWaitService().loadEntry()
            let refreshDate = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date().addingTimeInterval(20 * 60)
            completion(Timeline(entries: [entry], policy: .after(refreshDate)))
        }
    }
}

struct TPAWaitWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TPAWaitProvider.Entry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    private var smallView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.14, blue: 0.28), Color(red: 0.00, green: 0.42, blue: 0.61)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 8) {
                header

                Spacer()

                if let waitMinutes = entry.waitMinutes {
                    Text("\(waitMinutes)m")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Estimated security wait")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                } else {
                    Text("No live estimate")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(entry.errorMessage ?? "Source unavailable")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                }

                Spacer()

                footer
            }
            .padding(14)
        }
        .containerBackground(for: .widget) { }
    }

    private var mediumView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.17), Color(red: 0.00, green: 0.38, blue: 0.56)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    header

                    if let waitMinutes = entry.waitMinutes {
                        Text("\(waitMinutes)m")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(entry.waitDescription.capitalized)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                    } else {
                        Text("Unavailable")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text(entry.errorMessage ?? "Source unavailable")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(3)
                    }

                    Spacer()

                    footer
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("PreCheck")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))

                    ForEach(entry.checkpointStatuses, id: \.self) { checkpoint in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(checkpoint.status.lowercased() == "open" ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(checkpoint.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 8)
                            Text(checkpoint.status)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(16)
        }
        .containerBackground(for: .widget) { }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TPA")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text("Airport Wait")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private var footer: some View {
        Text("Source: TSA Wait Times • \(entry.fetchedAt, style: .relative)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(2)
    }
}

struct TPAWaitWidget: Widget {
    let kind: String = "TPAWaitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TPAWaitProvider()) { entry in
            TPAWaitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("TPA Wait Time")
        .description("Tracks the current Tampa airport security wait estimate.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TPAWaitWidgetBundle: WidgetBundle {
    var body: some Widget {
        TPAWaitWidget()
    }
}

private actor TPAWaitService {
    private let pageURL = URL(string: "https://www.tsawaittimes.com/security-wait-times/TPA/Tampa-International")!

    func loadEntry() async -> TPAWaitEntry {
        do {
            let (data, _) = try await URLSession.shared.data(from: pageURL)
            let payload = try parsePayload(from: data)

            return TPAWaitEntry(
                date: Date(),
                fetchedAt: Date(),
                waitMinutes: payload.roundedMinutes,
                waitDescription: payload.waitDescription,
                checkpointStatuses: payload.checkpointStatuses,
                errorMessage: nil
            )
        } catch {
            return TPAWaitEntry(
                date: Date(),
                fetchedAt: Date(),
                waitMinutes: nil,
                waitDescription: "",
                checkpointStatuses: [],
                errorMessage: "Could not refresh TPA wait estimate."
            )
        }
    }

    private func parsePayload(from data: Data) throws -> ParsedWaitPayload {
        guard let html = String(data: data, encoding: .utf8) else {
            throw TPAWaitError.invalidHTML
        }

        guard let waitMatch = html.firstMatch(of: #/(\d+)\s+minutes(?:\s+and\s+(\d+)\s+seconds)?\*/#) else {
            throw TPAWaitError.payloadNotFound
        }

        let minutes = Int(waitMatch.1) ?? 0
        let seconds = waitMatch.2.flatMap { Int($0) } ?? 0
        let roundedMinutes = minutes + (seconds >= 30 ? 1 : 0)
        let description = seconds > 0 ? "\(minutes) minutes and \(seconds) seconds" : "\(minutes) minutes"

        let checkpointMatches = html.matches(of: #/Airside\s+([A-Z])\s+(Open|Closed|Unavailable)/#)
        let checkpointStatuses = checkpointMatches.map {
            CheckpointStatus(name: String($0.1), status: String($0.2))
        }

        return ParsedWaitPayload(
            roundedMinutes: roundedMinutes,
            waitDescription: description,
            checkpointStatuses: checkpointStatuses
        )
    }
}

private struct ParsedWaitPayload {
    let roundedMinutes: Int
    let waitDescription: String
    let checkpointStatuses: [CheckpointStatus]
}

private extension String {
    func matches(of regex: Regex<(Substring, Substring, Substring)>) -> [Regex<(Substring, Substring, Substring)>.Match] {
        var output: [Regex<(Substring, Substring, Substring)>.Match] = []
        var searchStart = startIndex

        while searchStart < endIndex,
              let match = self[searchStart...].firstMatch(of: regex) {
            output.append(match)
            searchStart = match.range.upperBound
        }

        return output
    }
}

private enum TPAWaitError: Error {
    case invalidHTML
    case payloadNotFound
}
