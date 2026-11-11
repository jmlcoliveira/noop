#if os(iOS)
import SwiftUI
import StrandDesign

/// A full-width calendar gives the graphical picker the space it needs on compact iPhones.
struct PulseCalendarSheet: View {
    @Binding var selection: Date
    let latestDay: Date
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                DatePicker("Day", selection: $selection, in: ...latestDay,
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: PulseScreenStyle.calendarMaxWidth)
                    .padding(NoopMetrics.space3)
                    .frame(maxWidth: .infinity)
            }
            .background(PulsePageBackground().ignoresSafeArea())
            .navigationTitle("Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .tint(NoopVisualStyle.mint)
        }
        .presentationDetents([.height(PulseScreenStyle.calendarHeight), .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
