import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let sessionPrepOpenFolder = Notification.Name("sessionPrepOpenFolder")
    static let sessionPrepAddFiles = Notification.Name("sessionPrepAddFiles")
}

struct ContentView: View {
    @State private var folderURL: URL?
    @State private var records: [AudioFileRecord] = []
    @State private var selection: Set<AudioFileRecord.ID> = []
    /// Click-header sorting for the main table. `records` itself stays in
    /// scan order — this is applied only where it's displayed (see `table`
    /// below), so all the by-id row lookups elsewhere (bindings, selection,
    /// counts) don't need to know or care about display order.
    @State private var sortOrder: [KeyPathComparator<AudioFileRecord>] = []
    /// Immediate child folders of `folderURL` (not recursive — see
    /// FolderScanner's own non-recursive scope), shown as clickable chips
    /// under the path bar so folders created by processing (e.g. "Source -
    /// Stereo", "Processed - Mono") are actually reachable from the main
    /// window instead of only via Finder.
    @State private var subfolders: [URL] = []
    /// Which subfolder chip Cmd+Left/Right is currently pointed at — moving
    /// the highlight doesn't navigate by itself; Cmd+Down commits into it.
    /// Reset to nil any time `subfolders` is repopulated (see `scan`), so a
    /// stale highlight never survives into a folder it no longer applies to.
    @State private var highlightedSubfolderIndex: Int?
    /// Ancestor folders to go back to via the "Up" chip — pushed to when
    /// navigating into a subfolder chip, popped when going up. Reset to
    /// empty any time a brand-new folder is chosen from outside (clicking
    /// the folder path, drag-and-drop), since that starts a fresh session
    /// rather than continuing a walk down the tree.
    @State private var folderHistory: [URL] = []
    @State private var isScanning = false
    /// True only once a scan has been running long enough to be worth
    /// showing the busy overlay for (see the isScanning onChange below) —
    /// scanning a small subfolder chip you just clicked into finishes in a
    /// handful of milliseconds, and flashing the dimmed overlay on and back
    /// off that fast reads as a glitch rather than useful feedback.
    @State private var showScanningOverlay = false
    @State private var scanningOverlayWorkItem: DispatchWorkItem?
    @State private var scanProgress: Double = 0
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
    @State private var isHoveringFolderPath = false
    /// Set right before showing the Replace/Append/Cancel confirmation —
    /// the folder waiting on a decision. Cleared once the dialog resolves
    /// (any of the three buttons) so a stale value never lingers.
    @State private var pendingFolderOpen: URL?
    @State private var showingFolderOpenGuard = false
    @State private var showingResetConfirm = false
    /// Format/Bit Depth/Sample Rate/Peak/RMS/Written are always visible —
    /// Duration and Size are the two columns folded behind this toggle.
    /// Session-only, not persisted — starts hidden every launch.
    @State private var showFileDetail = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: 0) {
                    folderBar
                    // Subfolder chip navigation is commented out here as a
                    // deliberate experiment, not deleted — see
                    // subfolderBar/navigateInto/navigateUp/etc. further
                    // down in this file, and Session-Prep-Handoff-Notes.md
                    // item 9. Now that Add Files + Select Folder (below)
                    // reach any file on disk directly, in-app folder-to-
                    // folder navigation was mostly an incidental-access
                    // surface — a stray click or Cmd+arrow landing you in a
                    // folder you didn't mean to open — without adding real
                    // capability those two entry points don't already
                    // cover. One-line revert: uncomment this line and the
                    // matching `subfolderNavigationShortcuts` background
                    // below if it turns out to be missed.
                    // subfolderBar
                    Divider()
                    previewBar
                }
                Divider()
                GoniometerView()
                    .padding(12)
            }
            // Without this, the plain Divider() above (a direct HStack
            // child wanting to fill all available height) makes this whole
            // row report itself as vertically flexible, so the outer
            // VStack hands it a big share of the window's leftover height
            // — pushing the actual (small, fixed-size) row content down
            // into the middle of that oversized space instead of hugging
            // the top. This pins the row to its natural height instead.
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if records.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 1380, minHeight: 760)
        // Reset moved out of folderBar and into the title bar, next to the
        // app name — a real toolbar item, unlike the earlier empty-
        // principal-item title-centering experiment that didn't visibly
        // take effect and was reverted. This one has actual content, so
        // it should render regardless.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    resetBatch()
                } label: {
                    Label("Reset", systemImage: "xmark.circle")
                }
                .disabled(records.isEmpty)
            }
        }
        // Subfolder chip keyboard shortcuts (Cmd+Left/Right/Down) — commented
        // out along with subfolderBar above; see the comment at that call
        // site for why. subfolderNavigationShortcuts itself is left intact.
        // .background {
        //     subfolderNavigationShortcuts
        //         .frame(width: 0, height: 0)
        //         .opacity(0)
        // }
        .overlay {
            if showScanningOverlay || isConverting {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    BusyOverlayView(
                        progress: isConverting ? conversionProgress : (isScanning ? scanProgress : nil)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 20)
                }
            }
        }
        .onChange(of: isScanning) { scanning in
            scanningOverlayWorkItem?.cancel()
            if scanning {
                let workItem = DispatchWorkItem { showScanningOverlay = true }
                scanningOverlayWorkItem = workItem
                // Only shows up if the scan is still running after this
                // delay — a folder switch that completes before then never
                // shows the overlay at all, so nothing to flash off either.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            } else {
                showScanningOverlay = false
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
        .onReceive(NotificationCenter.default.publisher(for: .sessionPrepAddFiles)) { _ in
            addFilesViaPanel()
        }
        .onChange(of: selection) { _ in
            updatePreviewLoad()
        }
        // Replace/Append/Cancel — shown whenever a folder-open action
        // (Select Folder…, or dropping a folder) would otherwise silently
        // discard files already in the batch. Adding individual files
        // (Add Files…, dropping loose files) never goes through this —
        // appending can't lose anything, so there's nothing to confirm.
        .confirmationDialog(
            "This folder will affect your current batch",
            isPresented: $showingFolderOpenGuard,
            presenting: pendingFolderOpen
        ) { url in
            Button("Replace Batch") { commitFolderOpen(url, action: .replace) }
            Button("Append to Batch") { commitFolderOpen(url, action: .append) }
            Button("Cancel", role: .cancel) { pendingFolderOpen = nil }
        } message: { url in
            Text("\(records.count) file\(records.count == 1 ? "" : "s") already loaded. Replace the batch with \u{201c}\(url.lastPathComponent)\u{201d}, or add its files to what\u{2019}s already here?\n\nSet a standing default in Settings \u{25b8} Batch to stop asking.")
        }
        .alert("Clear the current batch?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) { performReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(records.count) file\(records.count == 1 ? "" : "s") from the list. Nothing is deleted from disk.")
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
            // Add Files… and Select Folder… are the two ways files enter
            // the batch — kept adjacent, Add Files first (it's the
            // non-destructive one, never guarded), with the folder path
            // trailing right after Select Folder… rather than splitting
            // the two file-picker commands across the row. Reset lives in
            // the title bar now, next to the app name.
            Button {
                addFilesViaPanel()
            } label: {
                Label("Add Files…", systemImage: "plus")
            }

            folderPathControl

            Spacer()

            Toggle(showFileDetail ? "Hide File Details" : "Show File Details", isOn: $showFileDetail)
                .toggleStyle(.button)
                .help("Duration and Size — hidden by default")
                .disabled(records.isEmpty)
        }
        .padding(12)
    }

    /// Select Folder… stays visible and reachable at all times now — it's
    /// no longer the only action in the row once a folder's loaded (Add
    /// Files/Reset/File Details sit next to it), so picking a different
    /// folder is still one click away without first hunting for where the
    /// control went. The path itself, when there is one, sits right after
    /// it — still clickable (same action as the button) with the same
    /// hover treatment as before, just no longer swapped in for the button.
    @ViewBuilder
    private var folderPathControl: some View {
        HStack(spacing: 6) {
            Button {
                chooseFolder()
            } label: {
                Label("Select Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            if let folderURL {
                Button {
                    chooseFolder()
                } label: {
                    Text(folderURL.path)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(isHoveringFolderPath ? 0.08 : 0))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringFolderPath = hovering
                    // .set() rather than push()/pop() — push/pop require a
                    // balanced pair, and if this view is swapped out (e.g.
                    // Reset flips folderURL to nil) while still hovered, the
                    // matching pop() might never fire, leaving the pointing
                    // hand stuck forever. set() has no stack to unbalance.
                    (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
        }
    }

    /// Subfolder chips + an "Up" chip, sitting right under the path row.
    /// Always present at a fixed height — whether or not there's a folder,
    /// subfolders, or history to show — so the rest of the window (preview
    /// bar, table) never shifts up/down as chips come and go.
    private var subfolderBar: some View {
        HStack(spacing: 6) {
            Text("Sub Folders:")
                .font(.caption)
                .foregroundColor(.secondary)
                // Extra indent beyond the bar's own horizontal padding,
                // reinforcing visually that this whole row is subordinate
                // to the folder path row above it.
                .padding(.leading, 12)

            // Always visible, just dimmed + inert when there's no history
            // to go back to — never removed from the layout, so nothing to
            // its right shifts as you navigate in and out of folders.
            Button {
                navigateUp()
            } label: {
                Label("Up", systemImage: "arrow.up")
                    .font(.caption)
            }
            .buttonStyle(folderChipStyle)
            .disabled(folderHistory.isEmpty)
            .opacity(folderHistory.isEmpty ? 0.4 : 1)
            // Matches Finder's own "move to enclosing folder" shortcut.
            .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(subfolders.indices, id: \.self) { index in
                        Button {
                            navigateInto(subfolders[index])
                        } label: {
                            Label(subfolders[index].lastPathComponent, systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(folderChipStyle)
                        // Cmd+Left/Right highlight ring — a click still
                        // navigates immediately regardless of this state,
                        // same as it always has.
                        .overlay {
                            if highlightedSubfolderIndex == index {
                                Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// A quiet green capsule chip — plain button chrome (no native tint, so
    /// the label stays the app's normal text color and the fill doesn't
    /// desaturate when the app loses focus the way a system-tinted control
    /// would) with just a light green background, same visual weight as
    /// StatusBadge's colored capsules elsewhere in the app.
    private var folderChipStyle: FolderChipButtonStyle { FolderChipButtonStyle() }

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
            Text("IngestIQ measures every audio file in the folder and flags stereo files that are actually dual mono, panned mono, polarity-inverted, or silent-channel, so you can convert them to true mono.")
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
                // Plain click: just the auto-fix categories (Dual Mono,
                // Panned, Polarity Inverted, Silent Channel), matching the
                // checkbox's own displayed state. Option-click reaches
                // everything else actionable too — True Stereo and Needs
                // Review default to Split to L/R (same as checking either
                // row's own checkbox from idle), Already Mono to Peak
                // Safety on — a true "select all," not just the auto-fix
                // rows. NSEvent.modifierFlags reads live keyboard state at
                // click time; SwiftUI's Toggle gives no modifier info of
                // its own.
                let selectEverything = NSEvent.modifierFlags.contains(.option)
                for idx in records.indices {
                    if records[idx].status.isConvertible {
                        records[idx].isSelectedForConversion = newValue
                    } else if selectEverything {
                        if records[idx].status == .trueStereo {
                            records[idx].trueStereoAction = newValue ? .split : .leaveAsIs
                        } else if records[idx].status == .alreadyMono {
                            records[idx].applyPeakSafetyToMono = newValue
                        } else if isNeedsReview(records[idx]) {
                            records[idx].needsReviewAction = newValue ? .split : .leaveAsIs
                        }
                    }
                }
            }
        )
    }

    /// Conditionally *including/excluding* a TableColumn inside a single
    /// @TableColumnBuilder body needs macOS 14.4's
    /// TableColumnBuilder.buildOptional — this project targets 13, so
    /// that's not available. Instead: two always-unconditional column
    /// groups (coreColumns, fileDetailColumns — see below) get combined
    /// into two complete, statically-built Table instances, and a plain
    /// `@ViewBuilder switch` (ordinary View-level branching, unrelated to
    /// the 14.4 gap above) picks the right one for the current toggle
    /// state. Same pattern used in Session Close for its own column
    /// show/hide toggles.
    @ViewBuilder
    private var table: some View {
        switch showFileDetail {
        case false:
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                primaryColumns
                coreColumns
            }
            .overlay(alignment: .topLeading) { selectAllOverlay }
        case true:
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                primaryColumns
                coreColumns
                fileDetailColumns
            }
            .overlay(alignment: .topLeading) { selectAllOverlay }
        }
    }

    /// The checkbox column's header title is "" — Table can't accept a
    /// custom view inside its own native header cell on macOS 13, so this
    /// was previously a separate strip stacked above the table, which read
    /// as a floating extra row rather than looking inline with "Filename"/
    /// "Format"/etc. Overlaying it directly onto that blank header cell
    /// puts it in the actual header row instead of a second one above it.
    /// The offset is a best-effort guess at the native header's cell
    /// padding since I can't see the rendered pixels myself — nudge x/y and
    /// tell me which way if it's off. Factored out of `table` so both
    /// showFileDetail branches above can share it without repeating the
    /// Toggle itself.
    private var selectAllOverlay: some View {
        Toggle("", isOn: selectAllConvertibleBinding)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!records.contains(where: {
                $0.status.isConvertible || $0.status == .trueStereo || $0.status == .alreadyMono || isNeedsReview($0)
            }))
            .help("Select all. Option-click to also include True Stereo, Already Mono, and Needs Review rows.")
            .offset(x: 16, y: 5)
    }

    /// First group — kept under the 10-column-per-builder limit alongside
    /// coreColumns/fileDetailColumns below. Checkbox and Action sit
    /// together up front (the two things you set), followed by Status and
    /// Filename (the two things you read to know what a row is) — every
    /// technical/measurement column comes after, in coreColumns.
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var primaryColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
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
            } else if case .needsReview = record.status {
                // Same three-way shape as True Stereo above: checking from
                // idle defaults to Split to L/R, the dropdown is where you
                // reach for Peak Safety specifically.
                Toggle("", isOn: needsReviewCheckboxBinding(for: record)).labelsHidden()
            } else {
                Image(systemName: "minus").foregroundColor(.secondary)
            }
        }
        .width(24)

        // 130 matches the Picker's own .frame(width:) in actionCell — a
        // Picker won't shrink below its frame, so that's the real floor;
        // the longest static description text ("Convert to mono (keep L)")
        // fits comfortably under that too.
        TableColumn("Action") { record in
            actionCell(for: record)
        }
        .width(140)

        // 135 fits the longest status label ("Silent Right Channel") inside
        // StatusBadge's capsule (dot + 8pt horizontal padding either side).
        TableColumn("Status", value: \.status.label) { record in
            StatusBadge(status: record.status)
        }
        .width(135)

        // Read-only preview of the Peak Safety/Leveling cut Process
        // Selected would currently apply — see MonoConverter.
        // suggestedGainDB. Not itself a settings surface: adjust the
        // levers in Settings/the Process Selected sheet, this just
        // reflects them.
        // Same story as Format/Bit Depth/Sample Rate below — "Suggested
        // Gain" (14 chars) is longer than any real value ("-12.0 dB", "—"),
        // so the header sets the floor here too.
        TableColumn("Suggested Gain") { record in
            Text(suggestedGainSummary(record))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .width(90)

        TableColumn("Filename", value: \.filename) { record in
            Text(record.filename).lineLimit(1)
        }
        .width(min: 180, ideal: 260)
    }

    /// Always-visible technical/measurement columns, in order right after
    /// Filename: True Peak L/R · RMS L/R · Format · Bit Depth · Sample Rate
    /// · Written. Duration and Size are the two that fold behind the File
    /// Details toggle instead (see fileDetailColumns below) — everything
    /// else here is either a quick QC read (True Peak/RMS) or short enough
    /// (Format/Bit Depth/Sample Rate/the Written checkmark) to stay on by
    /// default without crowding the table.
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var coreColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
        TableColumn("True Peak L/R", value: \.peakSortValue) { record in
            Text(peakSummary(record)).font(.system(size: 11, design: .monospaced))
        }
        .width(105)

        TableColumn("RMS L/R", value: \.rmsSortValue) { record in
            Text(rmsSummary(record)).font(.system(size: 11, design: .monospaced))
        }
        .width(100)

        // "Format" (6 chars) is longer than any real value (WAV, AIFF,
        // FLAC, ALAC — all ≤4), same for "Bit Depth" vs. "16-bit"/"24-bit"/
        // "32-bit" and "Sample Rate" vs. "44.1k"/"48.0k"/"96.0k" — the
        // header text is what actually sets the floor on these three, not
        // the content. Narrowed accordingly.
        TableColumn("Format", value: \.fileExtension) { record in
            Text(record.fileExtension.uppercased())
        }
        .width(50)

        TableColumn("Bit Depth", value: \.bitDepthSortValue) { record in
            Text(record.bitDepth.map { "\($0)-bit" } ?? "—")
        }
        .width(60)

        TableColumn("Sample Rate", value: \.sampleRate) { record in
            Text(formattedSampleRate(record.sampleRate))
        }
        .width(66)

        // Only meaningful confirmation signal for an in-place run (output
        // written beside the source, nothing to navigate to) — see
        // processSelected(). `convertedURL` was already declared on
        // AudioFileRecord for exactly this and simply wasn't being set
        // anywhere yet.
        TableColumn("Written") { record in
            if let writtenURL = record.convertedURL {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .help("Wrote \(writtenURL.lastPathComponent)")
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
        .width(50)
    }

    /// Duration · Size — folded in via the File Details toggle in
    /// folderBar (see `table` above and `showFileDetail`). Default hidden:
    /// useful reference detail, but not what you need to look at to decide
    /// which files to convert.
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var fileDetailColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
        TableColumn("Duration", value: \.duration) { record in
            Text(formattedDuration(record.duration))
        }
        .width(60)

        TableColumn("Size", value: \.fileSizeBytes) { record in
            Text(formattedSize(record.fileSizeBytes))
        }
        .width(70)
    }

    /// Auto-fix rows show a fixed description (nothing to choose). True
    /// Stereo and Needs Review rows get the same three-way dropdown (Leave
    /// As Is / Peak Safety / Split to L/R) and Already Mono rows a two-way
    /// one (Leave As Is / Peak Safety) — all are opt-in, Leave As Is is
    /// always the default, so nothing is ever written without a deliberate
    /// per-row choice. Only silence and Error have no action. Picker frame
    /// width (130) is what actually sets the Action column's floor — see
    /// TableColumn("Action").width below — since a Picker doesn't shrink to
    /// fit its container on its own.
    @ViewBuilder
    private func actionCell(for record: AudioFileRecord) -> some View {
        if let description = record.status.actionDescription {
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(polarityInvertedHelpText(for: record.status) ?? "")
        } else if record.status == .trueStereo {
            Picker("", selection: trueStereoActionBinding(for: record)) {
                Text("Leave As Is").tag(AudioFileRecord.TrueStereoAction.leaveAsIs)
                Text("Peak Safety").tag(AudioFileRecord.TrueStereoAction.peakSafety)
                Text("Split to L/R").tag(AudioFileRecord.TrueStereoAction.split)
            }
            .labelsHidden()
            .frame(width: 130)
        } else if record.status == .alreadyMono {
            Picker("", selection: monoPeakSafetyBinding(for: record)) {
                Text("Leave As Is").tag(false)
                Text("Peak Safety").tag(true)
            }
            .labelsHidden()
            .frame(width: 130)
        } else if case .needsReview = record.status {
            Picker("", selection: needsReviewActionBinding(for: record)) {
                Text("Leave As Is").tag(AudioFileRecord.NeedsReviewAction.leaveAsIs)
                Text("Peak Safety").tag(AudioFileRecord.NeedsReviewAction.peakSafety)
                Text("Split to L/R").tag(AudioFileRecord.NeedsReviewAction.split)
            }
            .labelsHidden()
            .frame(width: 130)
        } else {
            Text("—").foregroundColor(.secondary)
        }
    }

    /// Polarity Inverted's Action text used to spell out "auto-picked"
    /// inline — that was both the longest string in the column and the
    /// reason it needed to stay wide. Shortened to match every other
    /// case's length (see FileStatus.actionDescription); the "why this
    /// channel" detail lives here now, on hover, instead.
    private func polarityInvertedHelpText(for status: FileStatus) -> String? {
        guard case .polarityInverted(let keep) = status else { return nil }
        return "Channel auto-picked by comparing per-channel noise floor — \(keep.rawValue) measured cleaner."
    }

    /// Rows a checkbox/dropdown click on `record` should apply to. If
    /// `record` is part of an active multi-row highlight (shift/cmd-click),
    /// every other highlighted row matching `predicate` (same applicable
    /// category — e.g. only other True Stereo rows for the True Stereo
    /// dropdown) comes along for the same change. Clicking a row that isn't
    /// part of a multi-row highlight still only ever affects that one row.
    private func applyTargets(for record: AudioFileRecord, matching predicate: (AudioFileRecord) -> Bool) -> [AudioFileRecord.ID] {
        guard selection.count > 1, selection.contains(record.id) else { return [record.id] }
        return records.filter { predicate($0) && selection.contains($0.id) }.map(\.id)
    }

    private func trueStereoActionBinding(for record: AudioFileRecord) -> Binding<AudioFileRecord.TrueStereoAction> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.trueStereoAction ?? .leaveAsIs },
            set: { newValue in
                for id in applyTargets(for: record, matching: { $0.status == .trueStereo }) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].trueStereoAction = newValue
                    }
                }
            }
        )
    }

    private func trueStereoCheckboxBinding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.trueStereoAction != .leaveAsIs },
            set: { newValue in
                for id in applyTargets(for: record, matching: { $0.status == .trueStereo }) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].trueStereoAction = newValue ? .split : .leaveAsIs
                    }
                }
            }
        )
    }

    private func monoPeakSafetyBinding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.applyPeakSafetyToMono ?? false },
            set: { newValue in
                for id in applyTargets(for: record, matching: { $0.status == .alreadyMono }) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].applyPeakSafetyToMono = newValue
                    }
                }
            }
        )
    }

    private func isNeedsReview(_ record: AudioFileRecord) -> Bool {
        if case .needsReview = record.status { return true }
        return false
    }

    private func needsReviewActionBinding(for record: AudioFileRecord) -> Binding<AudioFileRecord.NeedsReviewAction> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.needsReviewAction ?? .leaveAsIs },
            set: { newValue in
                for id in applyTargets(for: record, matching: isNeedsReview) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].needsReviewAction = newValue
                    }
                }
            }
        )
    }

    private func needsReviewCheckboxBinding(for record: AudioFileRecord) -> Binding<Bool> {
        Binding(
            get: { records.first(where: { $0.id == record.id })?.needsReviewAction != .leaveAsIs },
            set: { newValue in
                for id in applyTargets(for: record, matching: isNeedsReview) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].needsReviewAction = newValue ? .split : .leaveAsIs
                    }
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

                Button {
                    previewPlayer.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .frame(width: 16)
                }
                .foregroundStyle(previewPlayer.isLooping ? Color.accentColor : Color.secondary)
                .disabled(!canPreview)
                .help("Loop")

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

            Divider().frame(height: 28)

            peakSafetyLevelingControls

            Spacer()

            // Original-file handling, output location, and the suffix
            // toggle still live in the pre-flight review sheet (opened
            // below) — Peak Safety/Leveling moved out to the row on the
            // left instead, so adjusting them and watching the Suggested
            // Gain column react happens in the same place, live, without
            // opening a sheet. See BACKLOG.md's "Move Peak Safety /
            // Leveling controls onto the main window" item.
            Button("Process Selected…") {
                processOptions = ProcessOptions() // fresh per-run defaults
                showingProcessOptions = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedActionCount == 0 || isConverting)
        }
        .padding(12)
    }

    /// Peak Safety / Leveling, relocated here from the Process Selected
    /// sheet — see BACKLOG.md. Both are attenuate-only and fully
    /// independent (never gate each other); whichever wants the bigger cut
    /// wins, same as MonoConverter.combinedGain. Changing either updates
    /// the Suggested Gain column immediately, live. Sized at .body (not
    /// .caption like summaryCounts) so the toggles/fields are easy to hit
    /// and read — this is a control row, not a stat readout. Each field
    /// pairs a typeable TextField with a Stepper for 0.1 dB nudges by
    /// click; a real click-drag-to-scrub field would need a fully custom
    /// control, not attempted here.
    private var peakSafetyLevelingControls: some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) {
                Toggle("Peak Safety", isOn: $settings.peakSafetyEnabled)
                    .toggleStyle(.checkbox)
                TextField("", value: $settings.peakSafetyCeilingDBTP, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .disabled(!settings.peakSafetyEnabled)
                Stepper("", value: $settings.peakSafetyCeilingDBTP, in: -60...0, step: 0.1)
                    .labelsHidden()
                    .disabled(!settings.peakSafetyEnabled)
                Text("dBTP").foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Toggle("Leveling", isOn: $settings.levelingEnabled)
                    .toggleStyle(.checkbox)
                TextField("", value: $settings.levelingTargetDBFS, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .disabled(!settings.levelingEnabled)
                Stepper("", value: $settings.levelingTargetDBFS, in: -60...0, step: 0.1)
                    .labelsHidden()
                    .disabled(!settings.levelingEnabled)
                Text("dBFS").foregroundColor(.secondary)
            }
        }
        .font(.body)
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
        records.filter {
            ($0.status == .trueStereo && $0.trueStereoAction == .split) ||
            (isNeedsReview($0) && $0.needsReviewAction == .split)
        }
    }

    /// "Peak Safety" rows that aren't being converted or split — an
    /// Already Mono file with the option checked, a True Stereo file left
    /// as stereo but gain-adjusted, or a Needs Review file given the same
    /// treatment. MonoConverter.levelOnly() may still end up writing
    /// nothing for some of these (a file already within both limits is a
    /// silent no-op), so this count is "opted in," not a guarantee every
    /// one of them produces a file.
    private var toLevelRecords: [AudioFileRecord] {
        records.filter {
            ($0.status == .alreadyMono && $0.applyPeakSafetyToMono) ||
            ($0.status == .trueStereo && $0.trueStereoAction == .peakSafety) ||
            (isNeedsReview($0) && $0.needsReviewAction == .peakSafety)
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
                for id in applyTargets(for: record, matching: { $0.status.isConvertible }) {
                    if let idx = records.firstIndex(where: { $0.id == id }) {
                        records[idx].isSelectedForConversion = newValue
                    }
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
            requestFolderOpen(url)
        }
    }

    /// Single entry point for every action that would replace/extend the
    /// batch with a whole folder's contents (Select Folder…, dropping a
    /// folder). Nothing to lose yet ⇒ just scans. Otherwise: a remembered
    /// per-machine default (Settings ▸ Batch) applies without asking;
    /// failing that, shows the Replace/Append/Cancel confirmation.
    private func requestFolderOpen(_ url: URL) {
        guard !records.isEmpty else {
            commitFolderOpen(url, action: .replace)
            return
        }
        if let remembered = settings.rememberedFolderOpenAction {
            commitFolderOpen(url, action: remembered)
            return
        }
        pendingFolderOpen = url
        showingFolderOpenGuard = true
    }

    /// Carries out a folder-open decision made either by the user (via the
    /// confirmation dialog) or a remembered Settings default.
    private func commitFolderOpen(_ url: URL, action: FolderOpenAction) {
        pendingFolderOpen = nil
        switch action {
        case .replace:
            folderURL = url
            folderHistory = [] // starting a fresh session, not continuing a walk down the tree
            scan(folder: url)
        case .append:
            folderURL = url // most-recently-opened location, for the path bar
            scanToAppend(folder: url)
        }
    }

    /// Enter a subfolder chip — pushes the current folder onto history so
    /// "Up" can return to it, then scans the subfolder as the new current
    /// folder.
    private func navigateInto(_ folder: URL) {
        guard let current = folderURL else { return }
        folderHistory.append(current)
        folderURL = folder
        scan(folder: folder)
    }

    /// Pop the last ancestor off history and scan back into it.
    private func navigateUp() {
        guard let previous = folderHistory.popLast() else { return }
        folderURL = previous
        scan(folder: previous)
    }

    // MARK: Subfolder chip keyboard navigation

    /// Invisible, zero-size buttons that exist only to carry the Cmd+Left/
    /// Right/Down shortcuts — there's no single visible control for these
    /// the way Up has its own button, since Left/Right act on whichever
    /// chip is highlighted and Down has no on-screen target at all.
    @ViewBuilder
    private var subfolderNavigationShortcuts: some View {
        Button("", action: highlightPreviousSubfolder)
            .keyboardShortcut(.leftArrow, modifiers: .command)
        Button("", action: highlightNextSubfolder)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        Button("", action: enterHighlightedSubfolder)
            .keyboardShortcut(.downArrow, modifiers: .command)
    }

    /// Moves the highlight only — never navigates by itself. Stops at the
    /// last chip rather than wrapping (deliberately silent: this fires
    /// constantly from a held-down key, and a beep-per-keypress there would
    /// be far more annoying than useful).
    private func highlightNextSubfolder() {
        guard !subfolders.isEmpty else { return }
        if let current = highlightedSubfolderIndex {
            if current < subfolders.count - 1 { highlightedSubfolderIndex = current + 1 }
        } else {
            highlightedSubfolderIndex = 0
        }
    }

    /// Mirror of `highlightNextSubfolder` — starts from the last chip
    /// rather than the first, so "Left" still means something directional
    /// the very first time it's pressed.
    private func highlightPreviousSubfolder() {
        guard !subfolders.isEmpty else { return }
        if let current = highlightedSubfolderIndex {
            if current > 0 { highlightedSubfolderIndex = current - 1 }
        } else {
            highlightedSubfolderIndex = subfolders.count - 1
        }
    }

    /// Commits into whichever chip Cmd+Left/Right left highlighted. The
    /// highlight itself gets cleared as a side effect of `scan` repopulating
    /// `subfolders` for the new folder, not explicitly here.
    private func enterHighlightedSubfolder() {
        guard let index = highlightedSubfolderIndex, subfolders.indices.contains(index) else { return }
        navigateInto(subfolders[index])
    }

    /// Immediate child directories of `folder`, alphabetical, hidden ones
    /// excluded — not recursive, matching FolderScanner's own non-recursive
    /// scope for audio files.
    private static func listSubfolders(of folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Handles anything dropped onto the window. A dropped folder goes
    /// through the same Select-Folder-… path (full scan, subject to the
    /// Replace/Append/Cancel guard if the batch already has files); one or
    /// more dropped individual audio files are appended directly, same as
    /// Add Files…, with no guard — dragging files straight out of a
    /// session/export no longer requires hunting down their folder, and
    /// can't discard anything already loaded.
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

    /// The first dropped directory (if any) wins and goes through the
    /// folder-open path; any dropped regular files are appended. A drop can
    /// contain both — e.g. a folder alongside a couple of loose files — in
    /// which case the folder is treated as the folder-open target and the
    /// loose files are appended on top of whatever that resolves to.
    private func resolveFolderFromDrop(_ urls: [URL]) {
        let fm = FileManager.default
        var directories: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                files.append(url)
            }
        }
        if let firstDirectory = directories.first {
            requestFolderOpen(firstDirectory)
        }
        if !files.isEmpty {
            addFiles(urls: files)
        }
    }

    /// Auto-checks the batch-inclusion checkbox for every auto-fix-category
    /// row (Dual Mono, Panned, Polarity Inverted, Silent Channel) a scan or
    /// add finds — these are the deterministic, safe-by-default
    /// conversions, unlike True Stereo/Already Mono/Needs Review, which
    /// stay opt-in (Leave As Is) since those involve an actual choice.
    /// Applied at both places new rows enter `records` (scan(folder:) and
    /// mergeIntoRecords) so "scan, then Process Selected" no longer needs
    /// a manual select-all click first, regardless of how the files
    /// arrived.
    private func autoSelectConvertible(_ records: [AudioFileRecord]) -> [AudioFileRecord] {
        records.map { record in
            var record = record
            if record.status.isConvertible {
                record.isSelectedForConversion = true
            }
            return record
        }
    }

    private func scan(folder: URL) {
        isScanning = true
        scanProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = FolderScanner.scan(folder: folder) { completed, total in
                DispatchQueue.main.async {
                    self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
                }
            }
            let childFolders = Self.listSubfolders(of: folder)
            DispatchQueue.main.async {
                self.records = self.autoSelectConvertible(scanned)
                self.subfolders = childFolders
                self.highlightedSubfolderIndex = nil // a stale highlight shouldn't survive into a folder it no longer applies to
                self.isScanning = false
            }
        }
    }

    /// Append variant of `scan(folder:)` for "Append to Batch" — scans
    /// `folder` the same way, but merges the results into the existing
    /// `records` instead of replacing them, skipping any file already
    /// present (by standardized URL) so re-opening the same folder twice
    /// doesn't duplicate rows.
    private func scanToAppend(folder: URL) {
        isScanning = true
        scanProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = FolderScanner.scan(folder: folder) { completed, total in
                DispatchQueue.main.async {
                    self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
                }
            }
            DispatchQueue.main.async {
                self.mergeIntoRecords(scanned)
                self.isScanning = false
            }
        }
    }

    /// Adds one or more individually-picked/dropped audio files to the
    /// batch, skipping anything outside FolderScanner's supported
    /// extensions and anything already present (by standardized URL).
    /// Always appends — never guarded, since nothing already loaded can be
    /// lost by adding more files.
    private func addFiles(urls: [URL]) {
        let candidates = urls.filter { FolderScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !candidates.isEmpty else { return }

        isScanning = true
        scanProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var analyzed: [AudioFileRecord] = []
            for (index, url) in candidates.enumerated() {
                analyzed.append(AudioFileAnalyzer.analyze(url: url))
                let completed = index + 1
                DispatchQueue.main.async {
                    self.scanProgress = Double(completed) / Double(candidates.count)
                }
            }
            DispatchQueue.main.async {
                self.mergeIntoRecords(analyzed)
                self.isScanning = false
            }
        }
    }

    /// "Add Files…" button/menu action — NSOpenPanel, multi-select, filtered
    /// to the same audio types FolderScanner recognizes.
    private func addFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose audio files to add to the batch"
        panel.allowedContentTypes = FolderScanner.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            addFiles(urls: panel.urls)
        }
    }

    /// Shared merge step for both scanToAppend and addFiles — dedupes
    /// against what's already in `records` by standardized file URL, so
    /// re-adding the same file (via a re-opened folder or a repeat drop)
    /// never produces a duplicate row.
    private func mergeIntoRecords(_ newRecords: [AudioFileRecord]) {
        let existingURLs = Set(records.map { $0.url.standardizedFileURL })
        let toAdd = newRecords.filter { !existingURLs.contains($0.url.standardizedFileURL) }
        records.append(contentsOf: autoSelectConvertible(toAdd))
    }

    private func resetBatch() {
        guard !records.isEmpty else { return }
        showingResetConfirm = true
    }

    private func performReset() {
        records = []
        selection = []
        subfolders = []
        folderHistory = []
        highlightedSubfolderIndex = nil
        folderURL = nil
    }

    /// One completed write, reported back from the background queue so the
    /// matching row's `convertedURL`/`movedOriginalURL`/`url` can be updated
    /// on the main thread once processing finishes.
    private struct ProcessedMark {
        let id: AudioFileRecord.ID
        let writtenURL: URL
        let movedOriginalURL: URL?
    }

    private func processSelected(options: ProcessOptions) {
        let toConvert = toConvertRecords
        let toSplit = toSplitRecords
        let toLevel = toLevelRecords
        let total = toConvert.count + toSplit.count + toLevel.count
        guard total > 0 else { return }

        // Decided up front, from every record currently in the batch (not
        // just the ones being processed this run) — rescanning `folderURL`
        // is only safe/accurate when every row already loaded lives in
        // that one folder. Once Add Files/append has brought in files from
        // elsewhere, a rescan would silently drop those other rows from
        // view (nothing lost on disk, just from the table) — see
        // Session-Prep-Handoff-Notes.md item 7. Mixed-source batches get
        // per-row checkmarks (item 6) instead of a rescan.
        let canRescanSharedFolder: Bool = {
            guard let folderURL else { return false }
            let standardizedFolder = folderURL.standardizedFileURL
            return records.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL == standardizedFolder }
        }()

        isConverting = true
        conversionProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = 0
            var failures: [String] = []
            var marks: [ProcessedMark] = []

            for record in toConvert {
                do {
                    let result = try MonoConverter.convert(record: record, sourceFolder: record.url.deletingLastPathComponent(), settings: settings, options: options)
                    marks.append(ProcessedMark(id: record.id, writtenURL: result.newMonoFileAt, movedOriginalURL: result.originalMovedTo))
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
                    let result = try MonoConverter.split(record: record, sourceFolder: record.url.deletingLastPathComponent(), settings: settings, options: options)
                    marks.append(ProcessedMark(id: record.id, writtenURL: result.leftFileAt, movedOriginalURL: result.originalMovedTo))
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
                    if let result = try MonoConverter.levelOnly(record: record, sourceFolder: record.url.deletingLastPathComponent(), settings: settings, options: options) {
                        marks.append(ProcessedMark(id: record.id, writtenURL: result.newMonoFileAt, movedOriginalURL: result.originalMovedTo))
                    }
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

                if canRescanSharedFolder, let folderURL = self.folderURL {
                    // Common case, unchanged from before: the whole batch
                    // came from one folder, so a rescan reflects reality —
                    // converted/split/moved originals disappear, new
                    // output files appear as rows — same as it always has.
                    self.scan(folder: folderURL)
                } else {
                    // Mixed-source batch (Add Files/append was used): don't
                    // rescan anything — mark the existing records in place
                    // instead, exactly the fix Session Close applied for
                    // the same shape of batch.
                    for mark in marks {
                        guard let idx = self.records.firstIndex(where: { $0.id == mark.id }) else { continue }
                        self.records[idx].convertedURL = mark.writtenURL
                        if let movedOriginalURL = mark.movedOriginalURL {
                            self.records[idx].movedOriginalURL = movedOriginalURL
                            // Keep `url` pointing at wherever the original
                            // actually lives now, so a later preview or
                            // re-process on this row doesn't reach for a
                            // file that's since moved.
                            self.records[idx].url = movedOriginalURL
                        }
                    }
                }
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

    /// True Peak (4x-oversampled, see TruePeakMeter.swift), not plain
    /// sample peak — can read hotter than 0 dBFS when inter-sample peaks
    /// reconstruct above what any single digital sample shows. Also what
    /// Suggested Gain is computed from — see MonoConverter.suggestedGainDB.
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

    /// Read-only preview of what Process Selected would currently apply —
    /// see MonoConverter.suggestedGainDB. "—" covers both "nothing
    /// measured yet" and "neither Peak Safety nor Leveling is on"; "0.0 dB"
    /// means both are on but this file's already within both limits.
    private func suggestedGainSummary(_ record: AudioFileRecord) -> String {
        guard let gainDB = MonoConverter.suggestedGainDB(for: record, settings: settings) else { return "—" }
        return String(format: "%.1f dB", gainDB)
    }
}

/// Plain button chrome, not a system tint — the label stays the app's
/// normal text color (a native `.tint()` would recolor the text green too,
/// which reads as louder than intended for a wayfinding control) and the
/// fill is a static color rather than system tint state, so it doesn't
/// desaturate when the app loses key window focus the way `.bordered` +
/// `.tint()` controls do.
private struct FolderChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(configuration.isPressed ? 0.30 : 0.18))
            .clipShape(Capsule())
    }
}
