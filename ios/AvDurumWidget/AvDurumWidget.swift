import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AvDurumWidgetBundle: WidgetBundle {
    var body: some Widget {
        AvDurumLiveActivity()
    }
}

private extension HuntActivityAttributes.ContentState {
    var color: Color {
        switch level {
        case 3: return .red
        case 2: return .orange
        case 1: return .green
        default: return .gray
        }
    }
    var icon: String {
        switch level {
        case 3: return "xmark.octagon.fill"
        case 2: return "exclamationmark.triangle.fill"
        case 1: return "checkmark.shield.fill"
        default: return "location.slash"
        }
    }
    var short: String {
        switch level {
        case 3: return L("AVLANMAYIN")
        case 2: return L("DİKKAT")
        case 1: return L("AVLANABİLİR")
        default: return "—"
        }
    }
}

struct AvDurumLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HuntActivityAttributes.self) { context in
            // Kilit ekranı ve Apple Watch Akıllı Yığın
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: context.state.icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(context.state.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title).font(.headline).lineLimit(2)
                    Text(context.state.detail).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let w = context.state.wind {
                            Label(w, systemImage: "wind").font(.caption2)
                        }
                        Text(context.state.updated, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(context.state.color.opacity(0.18))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.icon).font(.title).foregroundStyle(context.state.color)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail).font(.caption).lineLimit(2)
                        Spacer()
                        if let w = context.state.wind { Label(w, systemImage: "wind").font(.caption2) }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.icon).foregroundStyle(context.state.color)
            } compactTrailing: {
                Text(context.state.short).font(.caption2.bold()).foregroundStyle(context.state.color)
            } minimal: {
                Image(systemName: context.state.icon).foregroundStyle(context.state.color)
            }
        }
    }
}
