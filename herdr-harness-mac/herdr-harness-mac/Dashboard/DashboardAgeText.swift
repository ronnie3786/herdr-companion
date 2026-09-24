import SwiftUI

struct DashboardAgeText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(HerdrTimestamp.compactAge(since: date, now: context.date))
                .accessibilityLabel(HerdrTimestamp.spokenAge(since: date, now: context.date))
        }
    }
}
