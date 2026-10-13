import AppKit
import SwiftUI

struct ProfilesSettingsSection: View {
    @Bindable var store: ProviderProfilesStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var draftFamily: ProviderProfile.Family?
    @State private var draftName = ""
    @State private var draftFolder: String?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Profiles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                Text("Show another Claude config folder or Codex home as its own card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(store.profiles) { profile in
                    profileRow(profile)
                }
                if let draftFamily {
                    Divider()
                    addEditor(draftFamily)
                } else {
                    addRow
                }
                if let errorMessage {
                    inlineNotice(errorMessage)
                }
                if store.needsRelaunch {
                    restartRow
                }
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
    }

    // MARK: - Rows

    private func profileRow(_ profile: ProviderProfile) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(source: .providerMark(profile.family.rawValue))
                .frame(width: 18, height: 18)
            if renamingID == profile.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(profile) }
                Button("Save") { commitRename(profile) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { cancelRename() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(profile.family.displayName): \(profile.name)")
                        .lineLimit(1)
                    Text(abbreviated(profile.directory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                iconButton("folder", label: "Change Folder for \(profile.name)") { changeFolder(profile) }
                iconButton("pencil", label: "Rename \(profile.name)") { startRename(profile) }
                iconButton("trash", label: "Remove \(profile.name)") { remove(profile) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private var restartRow: some View {
        HStack(spacing: 8) {
            Text("Restart OpenUsage to apply profile changes.")
                .font(.caption)
                .foregroundStyle(Theme.notice)
            Spacer(minLength: 8)
            iconButton("arrow.clockwise", label: "Restart to Apply") { restart() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Text("Add Profile")
            Spacer(minLength: 8)
            Menu("Choose Provider") {
                ForEach(ProviderProfile.Family.allCases, id: \.self) { family in
                    Button(family.displayName) { startAdding(family) }
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func addEditor(_ family: ProviderProfile.Family) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New \(family.displayName) Profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text(draftFolder.map(abbreviated) ?? "No Folder Chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose Folder…") {
                    chooseFolder(for: family) { path in
                        draftFolder = path
                        errorMessage = nil
                    }
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("Save") { saveDraft(family) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftFolder == nil)
                Button("Cancel") { resetDraft() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    private func startAdding(_ family: ProviderProfile.Family) {
        cancelRename()
        resetDraft()
        draftFamily = family
    }

    private func resetDraft() {
        draftFamily = nil
        draftName = ""
        draftFolder = nil
        errorMessage = nil
    }

    private func chooseFolder(for family: ProviderProfile.Family, onChoose: @escaping (String) -> Void) {
        guard let window = NSApp.keyWindow else {
            errorMessage = "Couldn't open the folder picker. Try again."
            AppLog.error(.config, "profile folder picker could not open: no key window")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Choose"
        panel.message = family == .claude
            ? "Choose the Claude config folder (what CLAUDE_CONFIG_DIR points to)."
            : "Choose the Codex home (what CODEX_HOME points to)."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url.path)
        }
    }

    private func changeFolder(_ profile: ProviderProfile) {
        resetDraft()
        cancelRename()
        chooseFolder(for: profile.family) { path in
            do {
                try store.changeDirectory(profile.id, to: path)
                AppLog.info(.config, "profile folder changed for \(profile.family.rawValue)")
            } catch {
                errorMessage = error.localizedDescription
                AppLog.warn(.config, "profile folder not changed for \(profile.family.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private func restart() {
        do {
            AppLog.info(.config, "restarting to apply profile changes")
            try AppRelauncher.relaunch()
        } catch {
            errorMessage = "Couldn't restart OpenUsage. Quit and reopen it to apply profile changes."
            AppLog.error(.config, "restart to apply profile changes failed: \(error.localizedDescription)")
        }
    }

    private func saveDraft(_ family: ProviderProfile.Family) {
        guard let draftFolder else { return }
        do {
            try store.add(family: family, name: draftName, directory: draftFolder)
            AppLog.info(.config, "profile added for \(family.rawValue)")
            resetDraft()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.warn(.config, "profile not added for \(family.rawValue): \(error.localizedDescription)")
        }
    }

    private func startRename(_ profile: ProviderProfile) {
        resetDraft()
        renamingID = profile.id
        renameText = profile.name
    }

    private func cancelRename() {
        renamingID = nil
        renameText = ""
        errorMessage = nil
    }

    private func commitRename(_ profile: ProviderProfile) {
        do {
            try store.rename(profile.id, to: renameText)
            AppLog.info(.config, "profile renamed for \(profile.family.rawValue)")
            cancelRename()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.warn(.config, "profile not renamed for \(profile.family.rawValue): \(error.localizedDescription)")
        }
    }

    private func remove(_ profile: ProviderProfile) {
        store.remove(profile.id)
        AppLog.info(.config, "profile removed for \(profile.family.rawValue)")
        if renamingID == profile.id { cancelRename() }
    }
}
