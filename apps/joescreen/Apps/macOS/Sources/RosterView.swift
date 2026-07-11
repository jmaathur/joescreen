import SwiftUI
import JoeScreenKit

/// The participant roster, each entry in its deterministic `ParticipantColor` (spec §3.3). The local
/// participant is marked "(you)". Membership is driven by the transport/session participant stream.
struct RosterView: View {
    @Environment(AppModel.self) private var model

    private var sortedParticipants: [ParticipantID] {
        model.participants.sorted { $0.uuidString < $1.uuidString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Participants")
                    .font(.headline)
                Spacer()
                Text("\(model.participants.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            if sortedParticipants.isEmpty {
                Text("Waiting for participants…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(sortedParticipants, id: \.self) { id in
                    RosterRow(id: id, isLocal: id == model.localParticipantID)
                }
                .listStyle(.sidebar)
            }
            Spacer()
        }
    }
}

struct RosterRow: View {
    @Environment(AppModel.self) private var model
    let id: ParticipantID
    let isLocal: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.color(for: id))
                .frame(width: 12, height: 12)
            Text(model.displayLabel(for: id))
                .font(.body)
            if isLocal {
                Text("(you)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let count = model.room.windows(ownedBy: id).count
            if count > 0 {
                Image(systemName: "macwindow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
