import SwiftUI

struct StatusBadge: View {
    let status: FileStatus

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15))
        .clipShape(Capsule())
    }

    /// A full "X" is reserved for true full-file silence, so it doesn't
    /// look identical to "a channel is dead but the file has content."
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .noAudioContent:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(status.color)
        default:
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
        }
    }
}
