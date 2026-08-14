import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let sessionPrepOpenFolder = Notification.Name("sessionPrepOpenFolder")
}

struct ContentView: View {
    @State private var folderURL: URL?
    @State private var records: [AudioFileRecord] = []
    @State private var selection: Set<AudioFileRecord.ID> = []
    @State private var isScanning = false
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var previewPlayer = AudioPreviewPlayer.shared
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showingProcessOptions = false
    @State private var processOptions = ProcessOptions()
    @State private var isDropTargeted = false
    @State private var processingErrors: [String] = []
    @State private var showingProcessingErrors = false

    var body: some View {
        VStack(spacing: 0) {
            folderBar
            Divider()
            previewBar
            Divider()
            if records.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 1330, minHeight: 760)
        .overlay {
            if isScanning || isConverting {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    BusyOverlayView(
                        message: isScanning ? "Scanning folder…" : "Converting files…",
                        progress: isConverting ? conversionProgress : nil
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 20)
                }
            }
        }
        .overlay {
            // Visual feedback only while something's actually being dragged
            // over the window — an accent border, not a full takeover, so
            // it doesn't obscure what's already loaded.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionPrepOpenFolder)) { _ in
            chooseFolder()
        }
        .onChange(of: selection) { _ in
            updatePreviewLoad()
        }
        .sheet(isPresented: $showingProcessOptions) {
            // Fresh options every time the sheet opens — these are per-run
            // choices, not something that should carry over silently from
            // the last batch.
            ProcessOptionsSheet(
                toConvertCount: toConvertRecords.count,
                toSplitCount: toSplitRecords.count,
                toLevelCount: toLevelRecords.count,
                options: $processOptions,
                settings: settings,
                onCancel: { showingProcessOptions = false },
                onProcess: {
                    showingProcessOptions = false
                    processSelected(options: processOptions)
                }
            )
        }
        .alert("Some files couldn't be processed", isPresented: $showingProcessingErrors) {
            Button("OK") {}
        } message: {
            Text(processingErrors.joined(separator: "\n"))
        }
    }

    private func updatePreviewLoad() {
        // Anything should be auditionable, not just stereo files.
        if let record = selectedSingleRecord, record.channelCount == 1 || record.channelCount == 2 {
            previewPlayer.load(url: record.url)
        } else {
            previewPlayer.unload()
        }
    }

    // MARK: Folder bar

    private var folderBar: some View {
        HStack {
            Image(systemName: "folder").foregroundColor(.secondary)
            Text(folderURL?.path ?? "No folder selected")
                .foregroundColor(folderURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Select Folder…") { chooseFolder() }
            Button("Reset") { reset() }
                .disabled(folderURL == nil)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            // Dedicated transparent line-art mark (not the full app icon
            // tile) — the app icon's own background square showed through
            // at low opacity as a dull gray box. This asset has no fill
            // behind the linework, and swaps a dark/light variant
            // automatically with the system appearance (see
            // Assets.xcassets/WatermarkMark).
            Image("WatermarkMark")
                .resizable()
                .frame(width: 128, height: 128)
                .opacity(0.2)
            Text("Select a folder to scan")
                .font(.title3)
            Text("Drag a folder onto this window, or use Select Folder…")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Session Prep measures every audio file in the folder and flags stereo files that are actually dual mono, panned mono, polarity-inverted, or silent-channel, so you can convert them to true mono.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Table

    private var selectAllConvertibleBinding: Binding<Bool> {
        Binding(
            get: {
                let convertible = records.filter { $0.status.isConvertible }
                guard !convertible.isEmpty else { return false }
                return convertible.allSatisfy { $0.isSelectedForConversion }
            },
            set: { newValue in
                for idx in records.indices where records[idx].status.isConvertible {
                    records[idx].isSelectedForConversion = newValue
                }
            }
        )
    }

    private var table: some View {
        // Split across two grouped builders — SwiftUI's TableColumnBuilder
        // only supports up to 10 columns in one Table{} closure, and adding
        // "RMS L/R" pushed the total to 11 ("Extra argument in call" at
        // build time). Each group below is its own @TableColumnBuilder
        // function, so the outer Table{} only ever sees 2 components.
        Table(records, selection: $selection) {
            primaryColumns
            secondaryColumns
        }
        // The checkbox column's header title is "" — Table can't accept a
        // custom view inside its own native header cell on macOS 13, so
        // this was previously a separate strip stacked above the table,
        // which read as a floating extra row rather than looking inline
        // with "Filename"/"Format"/etc. Overlaying it directly onto that
        // blank header cell puts it in the actual header row instead of a
        // second one above it. The offset is a best-effort guess at the
        // native header's cell padding since I can't see the rendered
        // pixels myself — nudge x/y and tell me which way if it's off.
        .overlay(alignment: .topLeading) {
            Toggle("", isOn: selectAllConvertibleBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!records.contains(where: { $0.status.isConvertible }))
                .offset(x: 16, y: 5)
        }
    }

    /// First half of the column set — kept under the 10-column-per-builder
    /// limit alongside secondaryColumns below. Order here is purely visual
    /// (left-to-right column order); the split point isn't meaningful.
    /// Checkbox and Action sit together up front (the two things you set),
    /// followed by Status and Filename (the two things you read to know
    /// what a row is) — Format/Bit Depth/Sample Rate/Duration/Peak/RMS/Size
    /// are secondary technical detail, pushed to the tail end.
    @TableColumnBuilder<AudioFileRecord, Never>
    private var primaryColumns: some TableColumnContent<AudioFileRecord, Never> {
        TableColumn("") { record in
            if record.status.isConvertible {
                Toggle("", isOn: binding(for: record)).labelsHidden()
            } else if record.status == .trueStereo {
                // Reflects "not Leave As Is" — a plain checkbox can't
                // capture all three Action-column states, so checking it
                // from idle defaults to Split to L/R (matching the
                // checkbox's original meaning before Peak Safety existed
                // as an option here); the dropdown is where you reach for
                // Peak Safety specifically. The header "select all"
                // checkbox still doesn't touch this column — both True
                // Stereo and Already Mono stay deliberate per-row choices.
                Toggle("", isOn: trueStereoCheckboxBinding(for: record)).labelsHidden()
            } else if record.status == .alreadyMono {
                // Already Mono has just one real choice (Peak Safety
                // on/off), so the checkbox and the Action dropdown below
                // share the exact same binding — never two things that
                // could disagree.
                Toggle("", isOn: monoPeakSafetyBinding(for: record)).labelsHidden()
            } else {
                Image(systemName: "minus").foregroundColor(.secondary)
            }
        }
        .width(24)

        TableColumn("Action") { record in
            actionCell(for: record)
        }
        .width(165)

        TableColumn("Status") { record in
            StatusBadge(status: record.status)
        }
        .width(150)

        TableColumn("Filename") { record in
            Text(record.filename).lineLimit(1)
        }
        .width(min: 180, ideal: 260)

        TableColumn("Format") { record in
            Text(record.fileExtension.uppercased())
        }
        .width(60)

        TableColumn("Bit Depth") { record in
            Text(record.bitDepth.map { "\($0)-bit" } ?? "—")
        }
        .width(70)
    }

    /// Second half of the column set — see primaryColumns above.
    @TableColumnBuilder<AudioFileRecord, Never>
    private var secondaryColumns: some TableColumnContent<AudioFileRecord, Never> {
        TableColumn("Sample Rate") { record in
            Text(formattedSampleRate(record.sampleRate))
        }
        .width(80)

        TableColumn("Duration") { record in
            Text(formattedDuration(record.duration))
        }
        .width(60)

        TableColumn("Peak L/R") { record in
            Text(peakSummary(record)).font(.system(size: 11, design: .monospaced))
        }
        .width(110)

        TableColumn("RMS L/R") { record in
            Text(rmsSummary(record)).font(.system(size: 11, design: .monospaced))
        }
        .width(110)

        TableColumn("Size") { record in
            Text(formattedSize(record.fileSizeBytes))
        }
        .width(70)
    }

    /// Auto-fix rows show a fixed description (nothing to choose). True
    /// Stereo rows get a three-way dropdown (Leave As Is / Peak Safety /
    /// Split to L/R) and Already Mono rows a two-way one (Leave As Is /
    /// Peak Safety) — both are opt-in, Leave As Is is always the default,
    /// so nothing is ever written without a deliberate per-row choice.
    /// Everything else (silence, Needs Review, Error) has no action.
    @ViewBuilder
    private func actionCell(for record: AudioFileRecord) -> some View {
        if let description = record.status.actionDescription {
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        } else if record.status == .trueStereo {
            Picker("", selection: trueStereoActionBinding(for: record)) {
                Text("Leave As Is").tag(AudioFileRecord.TrueStereoAction.leaveAsIs)
                Text("Peak Safety").tag(AudioFileRecord.TrueStereoAction.peakSafety)
                Text("Split to L/R").tag(AudioFileRecord.TrueStereoAction.split)
            }
            .labelsHidden()
            .frame(width: 150)
        } else if record.status == .alreadyMono {
            Picker("", selection: monoPeakSafetyBinding(for: record)) {
                Text("Leave As Is").tag(false)
                Text("Peak Safety").tag(true)
            }
            .labelsHidden()
            .frame(width: 150)
        } else {
            Text("—").foregroundColor(.secondary)
        }
    }

    private func trueStereoActionBinding(for record: AudioFileRecord) -> Binding<AudioFileRecord.TrueStereoAction> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.trueStereoAction ?? .leaveAsIs },
            set: { newValue in
                if let idx = records.firstIndex(where: { $0.id == record.id }) {
                    records[idx].trueStereoAction = newValue
                }
            }
        )
    }

    private func trueStereoCheckboxBinding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.trueStereoAction != .leaveAsIs },
            set: { newValue in
                if let idx = records.firstIndex(where: { $0.id == record.id }) {
                    records[idx].trueStereoAction = newValue ? .split : .leaveAsIs
                }
            }
        )
    }

    private func monoPeakSafetyBinding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.applyPeakSafetyToMono ?? false },
            set: { newValue in
                if let idx = records.firstIndex(where: { $0.id == record.id }) {
                    records[idx].applyPeakSafetyToMono = newValue
                }
            }
        )
    }

    // MARK: Preview bar

    /// The one file to preview, if exactly one row is selected. Playback
    /// only makes sense for a single stereo file at a time.
    private var selectedSingleRecord: AudioFileRecord? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    /// Always renders the same transport layout — Play/Pause/Stop/mode
    /// picker/scrubber never disappear or get replaced by a placeholder,
    /// they just disable and gray out with nothing loaded. Keeps the
    /// controls in a fixed, predictable spot instead of the layout jumping
    /// depending on selection state.
    private var previewBar: some View {
        let record = selectedSingleRecord
        // Anything should be auditionable, not just stereo files.
        let canPreview = record != nil && (record!.channelCount == 1 || record!.channelCount == 2)

        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    previewPlayer.togglePlayPause()
                } label: {
                    Image(systemName: previewPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPreview)
                .keyboardShortcut(.space, modifiers: []) // standard media convention

                Button {
                    previewPlayer.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!canPreview || (!previewPlayer.isPlaying && previewPlayer.currentTime == 0))

                Text(record?.filename ?? "Select a file to preview it")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 120, alignment: .leading)

                Spacer(minLength: 8)

                // Mode can be changed live, mid-playback — switches to the
                // new combination from the current position rather than
                // requiring Stop first. Only meaningful for a stereo
                // source; a mono file has nothing to compare, so the
                // picker is swapped for a plain label of the same width
                // (keeps the layout from shifting).
                // Fixed height on both branches — a segmented Picker and a
                // plain Text report different intrinsic heights, and
                // without pinning them the whole preview bar (and
                // everything below it) would grow/shrink by a few points
                // every time selection switched between a mono and stereo
                // file, producing a visible jump.
                if previewPlayer.sourceChannelCount == 1 {
                    Text("Mono — single channel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 320, height: 22)
                } else {
                    Picker("", selection: $previewPlayer.mode) {
                        ForEach(AudioPreviewPlayer.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320, height: 22)
                    .disabled(!canPreview)
                }
            }
            .frame(height: 22)

            HStack(spacing: 8) {
                Text(formattedDuration(isScrubbing ? scrubTime : previewPlayer.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : previewPlayer.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(previewPlayer.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing {
                            scrubTime = previewPlayer.currentTime
                        }
                        isScrubbing = editing
                        if !editing {
                            previewPlayer.seek(to: scrubTime)
                        }
                    }
                )
                .disabled(!canPreview)

                Text(formattedDuration(previewPlayer.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            summaryCounts

            Spacer()

            // Peak Safety, original-file handling, output location, and the
            // suffix toggle all live in the pre-flight review sheet now
            // (opened below) rather than being split across the bottom bar
            // and Settings.
            Button("Process Selected…") {
                processOptions = ProcessOptions() // fresh per-run defaults
                showingProcessOptions = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedActionCount == 0 || isConverting)
        }
        .padding(12)
    }

    private var summaryCounts: some View {
        HStack(spacing: 14) {
            countLabel("Total", records.count)
            countLabel("Dual Mono", count { if case .dualMono = $0.status { return true }; return false })
            countLabel("Panned", count { if case .pannedMono = $0.status { return true }; return false })
            countLabel("Inverted", count { if case .polarityInverted = $0.status { return true }; return false })
            countLabel("Silent Ch.", count { if case .silentChannel = $0.status { return true }; return false })
            countLabel("True Stereo", count { $0.status == .trueStereo })
            countLabel("Splitting", count { $0.status == .trueStereo && $0.trueStereoAction == .split })
            countLabel("Peak Safety", toLevelRecords.count)
        }
        .font(.caption)
    }

    private func count(_ predicate: (AudioFileRecord) -> Bool) -> Int {
        records.filter(predicate).count
    }

    private func countLabel(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 13, weight: .semibold))
            Text(label).foregroundColor(.secondary)
        }
    }

    private var toConvertRecords: [AudioFileRecord] {
        records.filter { $0.isSelectedForConversion && $0.status.isConvertible }
    }

    private var toSplitRecords: [AudioFileRecord] {
        records.filter { $0.status == .trueStereo && $0.trueStereoAction == .split }
    }

    /// "Peak Safety" rows that aren't being converted or split — an
    /// Already Mono file with the option checked, or a True Stereo file
    /// left as stereo but gain-adjusted. MonoConverter.levelOnly() may
    /// still end up writing nothing for some of these (a file already
    /// within both limits is a silent no-op), so this count is "opted in,"
    /// not a guarantee every one of them produces a file.
    private var toLevelRecords: [AudioFileRecord] {
        records.filter {
            ($0.status == .alreadyMono && $0.applyPeakSafetyToMono) ||
            ($0.status == .trueStereo && $0.trueStereoAction == .peakSafety)
        }
    }

    private var selectedActionCount: Int {
        toConvertRecords.count + toSplitRecords.count + toLevelRecords.count
    }

    // MARK: Actions

    private func binding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.isSelectedForConversion ?? false },
            set: { newValue in
                if let idx = records.firstIndex(where: { $0.id == record.id }) {
                    records[idx].isSelectedForConversion = newValue
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select a folder containing audio files"
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
            scan(folder: url)
        }
    }

    /// Same effect as Select Folder…, just via drag-and-drop onto the
    /// window. Accepts either a dropped folder (used directly) or one or
    /// more dropped audio files — in which case the source folder is
    /// inferred as the first file's containing folder, so you can just drag
    /// files straight out of a session/export without hunting down the
    /// folder yourself first.
    private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
        let loadable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loadable.isEmpty else { return false }

        let group = DispatchGroup()
        var droppedURLs: [URL] = []
        let lock = NSLock()

        for provider in loadable {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.resolveFolderFromDrop(droppedURLs)
        }
        return true
    }

    /// A dropped folder wins outright; otherwise the first dropped file's
    /// parent folder is used as the scan target.
    private func resolveFolderFromDrop(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folderURL = url
                scan(folder: url)
                return
            }
        }
        if let firstFile = urls.first {
            let parent = firstFile.deletingLastPathComponent()
            folderURL = parent
            scan(folder: parent)
        }
    }

    private func reset() {
        folderURL = nil
        records = []
        selection = []
    }

    private func scan(folder: URL) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = FolderScanner.scan(folder: folder)
            DispatchQueue.main.async {
                self.records = scanned
                self.isScanning = false
            }
        }
    }

    private func processSelected(options: ProcessOptions) {
        guard let folderURL else { return }
        let toConvert = toConvertRecords
        let toSplit = toSplitRecords
        let toLevel = toLevelRecords
        let total = toConvert.count + toSplit.count + toLevel.count
        guard total > 0 else { return }

        isConverting = true
        conversionProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = 0
            var failures: [String] = []

            for record in toConvert {
                do {
                    _ = try MonoConverter.convert(record: record, sourceFolder: folderURL, settings: settings, options: options)
                } catch {
                    // Keep going with the rest of the batch rather than
                    // aborting on one bad file — but track it so it can be
                    // surfaced once the batch finishes, not just printed to
                    // a console nobody's watching outside Xcode.
                    failures.append("\(record.filename): \(error.localizedDescription)")
                }
                completed += 1
                let progress = Double(completed) / Double(total)
                DispatchQueue.main.async { self.conversionProgress = progress }
            }

            for record in toSplit {
                do {
                    _ = try MonoConverter.split(record: record, sourceFolder: folderURL, settings: settings, options: options)
                } catch {
                    failures.append("\(record.filename): \(error.localizedDescription)")
                }
                completed += 1
                let progress = Double(completed) / Double(total)
                DispatchQueue.main.async { self.conversionProgress = progress }
            }

            for record in toLevel {
                do {
                    // nil means the file was already within both limits —
                    // a silent no-op, not a failure, nothing to report.
                    _ = try MonoConverter.levelOnly(record: record, sourceFolder: folderURL, settings: settings, options: options)
                } catch {
                    failures.append("\(record.filename): \(error.localizedDescription)")
                }
                completed += 1
                let progress = Double(completed) / Double(total)
                DispatchQueue.main.async { self.conversionProgress = progress }
            }

            DispatchQueue.main.async {
                self.isConverting = false
                if !failures.isEmpty {
                    self.processingErrors = failures
                    self.showingProcessingErrors = true
                }
                // Re-scan so the table reflects post-conversion reality —
                // converted/split originals have moved out of the folder.
                self.scan(folder: folderURL)
            }
        }
    }

    // MARK: Formatting

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formattedSampleRate(_ rate: Double) -> String {
        guard rate > 0 else { return "—" }
        return String(format: "%.1fk", rate / 1000)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Plain sample peak, not True Peak — kept fast for the table since
    /// this runs on every scanned file. True Peak (4x oversampled, see
    /// TruePeakMeter.swift) is only measured at conversion time, for Peak
    /// Safety's gain decision.
    private func peakSummary(_ record: AudioFileRecord) -> String {
        guard let l = record.peakLeftDBFS else { return "—" }
        guard let r = record.peakRightDBFS else { return String(format: "%.1f", l) } // mono — one channel only
        return String(format: "%.1f / %.1f", l, r)
    }

    private func rmsSummary(_ record: AudioFileRecord) -> String {
        guard let l = record.rmsLeftDBFS else { return "—" }
        guard let r = record.rmsRightDBFS else { return String(format: "%.1f", l) } // mono — one channel only
        return String(format: "%.1f / %.1f", l, r)
    }
}
