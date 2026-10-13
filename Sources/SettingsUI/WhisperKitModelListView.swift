import SwiftUI

/// Model list with download progress, activation and removal.
struct WhisperKitModelListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var modelManager: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(WhisperModelManager.curated) { model in
                ModelRow(model: model)
            }

            if !WhisperModelManager.isDownloaded(settings.whisperKitModel) {
                Label(
                    "The active model is not downloaded yet. Download it above before dictating.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Text("Activating a model optimizes it for this Mac — again after each new app build or macOS update — which can take several minutes for large models. WhisperStorm does this in the background right after download or activation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { modelManager.refresh() }
    }
}

private struct ModelRow: View {
    let model: WhisperModelManager.ModelInfo

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var modelManager: WhisperModelManager

    private var isActive: Bool { settings.whisperKitModel == model.variant }
    private var state: ModelDownloadState { modelManager.state(for: model.variant) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(isActive ? .semibold : .regular)
                    Text(model.sizeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailingControls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch state {
        case .notDownloaded:
            Button("Download") { modelManager.download(model.variant) }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 110)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { modelManager.cancelDownload(model.variant) }
            }

        case .downloaded:
            HStack(spacing: 8) {
                if modelManager.preparingVariant == model.variant {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The first load after a new app build or a macOS update optimizes the model for this Mac — up to ~20 minutes for large models. Later loads take seconds.")
                } else if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Use") { settings.whisperKitModel = model.variant }
                    Button(role: .destructive) {
                        modelManager.remove(model.variant)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this model from disk")
                }
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Text("Failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(message)
                Button("Retry") { modelManager.download(model.variant) }
            }
        }
    }

    private var statusSymbol: String {
        switch state {
        case .downloaded: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .notDownloaded: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch state {
        case .downloaded: .green
        case .downloading: .cyan
        case .failed: .red
        case .notDownloaded: .secondary
        }
    }
}
