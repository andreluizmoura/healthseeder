import SwiftUI

struct ContentView: View {
    @StateObject private var seeder = HealthSeeder()
    @State private var showDeleteConfirmation = false
    @State private var showAuthStatus = false
    @State private var showResetInstructions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView
                if seeder.isRunning || seeder.isComplete {
                    progressSection
                }
                categoryList
                bottomBar
            }
            .navigationTitle("Health Seeder")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            await seeder.requestAuth()
        }
        .alert("Authorization Error", isPresented: .constant(seeder.authError != nil)) {
            Button("OK") { seeder.authError = nil }
        } message: {
            Text(seeder.authError ?? "")
        }
        .alert("Delete All Seeded Data?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await seeder.deleteAllSeededData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all samples written by HealthSeeder from Apple Health. This cannot be undone.")
        }
        .alert(deleteResultTitle, isPresented: .constant(seeder.deleteResult != nil)) {
            Button("OK") { seeder.deleteResult = nil }
        } message: {
            Text(deleteResultMessage)
        }
        .sheet(isPresented: $showAuthStatus) {
            if let summary = seeder.authStatusSummary {
                AuthStatusView(summary: summary) {
                    showAuthStatus = false
                } requestAuth: {
                    showAuthStatus = false
                    Task { await seeder.requestAuth() }
                }
            }
        }
        .sheet(isPresented: $showResetInstructions) {
            NuclearResetView { showResetInstructions = false }
        }
    }

    // MARK: - Delete alert helpers

    var deleteResultTitle: String {
        switch seeder.deleteResult {
        case .success: return "Deleted"
        case .failure: return "Error"
        case nil:      return ""
        }
    }

    var deleteResultMessage: String {
        switch seeder.deleteResult {
        case .success(let count): return "\(count) samples removed from Apple Health."
        case .failure(let msg):   return msg
        case nil:                 return ""
        }
    }

    // MARK: - Header

    var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text(seeder.todayOnly
                    ? "Injects realistic data into the Simulator's Apple Health for today only."
                    : "Injects realistic data into the Simulator's Apple Health for the last \(seeder.days) days."
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Text("Period:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Days", selection: $seeder.days) {
                    Text("Today only").tag(1)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days").tag(365)
                }
                .pickerStyle(.menu)
                .disabled(seeder.isRunning || seeder.isDeleting)
            }
            .padding(.horizontal)

            // Weight profile picker. Selects which analysis state the generated
            // body-mass series should drive the Weight Patterns feature to. The
            // weight series uses the profile's own history length, not the
            // Period picker above (which still governs every other category).
            HStack {
                Text("Weight profile:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Profile", selection: $seeder.selectedWeightProfile) {
                    ForEach(WeightProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .disabled(seeder.isRunning || seeder.isDeleting)
            }
            .padding(.horizontal)

            Text(seeder.selectedWeightProfile.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Progress

    var progressSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text(seeder.isComplete ? "Complete!" : "Seeding data...")
                    .font(.headline)
                    .foregroundStyle(seeder.isComplete ? .green : .blue)
                Spacer()
                Text("\(Int(seeder.overallProgress * 100))%")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: seeder.overallProgress)
                .tint(seeder.isComplete ? .green : .blue)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Category List

    var categoryList: some View {
        List {
            Section("\(seeder.categories.count) categories") {
                ForEach(seeder.categories.indices, id: \.self) { i in
                    let cat = seeder.categories[i]
                    HStack(spacing: 12) {
                        Image(systemName: cat.icon)
                            .frame(width: 28)
                            .foregroundStyle(statusColor(cat.status))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.name)
                                .font(.subheadline)
                            if cat.status == .done {
                                Text("\(cat.count) samples")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(cat.status.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                        statusIcon(cat.status)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Bottom Bar

    var bottomBar: some View {
        VStack(spacing: 10) {
            if seeder.isComplete {
                let failed = seeder.failedCount
                let done = seeder.categories.filter { $0.status == .done }.count
                if failed == 0 {
                    Label("All \(done) categories seeded. Open the Health app to review.", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                } else {
                    Label("\(done) seeded, \(failed) failed. Check Xcode console for details.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                Task { await seeder.seedAll() }
            } label: {
                Label(
                    seeder.isRunning ? "Seeding..." : (seeder.isComplete ? "Seed Again" : "Seed Health Data"),
                    systemImage: seeder.isRunning ? "arrow.triangle.2.circlepath" : "heart.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(seeder.isComplete ? .orange : .red)
            .disabled(seeder.isRunning || seeder.isDeleting)
            .controlSize(.large)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                if seeder.isDeleting {
                    HStack(spacing: 8) {
                        ProgressView().tint(.red)
                        Text("Deleting...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Delete All Seeded Data", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(seeder.isRunning || seeder.isDeleting)
            .controlSize(.large)

            Button {
                Task {
                    await seeder.checkAuthStatus()
                    showAuthStatus = true
                }
            } label: {
                if seeder.isCheckingAuth {
                    HStack(spacing: 8) {
                        ProgressView().tint(.blue)
                        Text("Checking...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Check Permissions", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(seeder.isRunning || seeder.isDeleting || seeder.isCheckingAuth)
            .controlSize(.large)

            Button {
                showResetInstructions = true
            } label: {
                Label("Full Health Reset (Simulator)", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(seeder.isRunning || seeder.isDeleting)
            .controlSize(.large)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Helpers

    func statusColor(_ status: SeedStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .running: return .blue
        case .done:    return .green
        case .failed:  return .red
        }
    }

    @ViewBuilder
    func statusIcon(_ status: SeedStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Auth Status Sheet

struct AuthStatusView: View {
    let summary: HealthSeeder.AuthStatusSummary
    let dismiss: () -> Void
    let requestAuth: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("\(summary.authorized) authorized", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("of \(summary.total)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    if summary.denied > 0 {
                        Label("\(summary.denied) denied", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    if summary.notDetermined > 0 {
                        Label("\(summary.notDetermined) not determined", systemImage: "questionmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Summary")
                }

                if !summary.denied_names.isEmpty {
                    Section("Denied") {
                        ForEach(summary.denied_names, id: \.self) { name in
                            HStack {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !summary.notDetermined_names.isEmpty {
                    Section("Not Determined") {
                        ForEach(summary.notDetermined_names, id: \.self) { name in
                            HStack {
                                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if summary.denied > 0 || summary.notDetermined > 0 {
                    Section {
                        Button {
                            requestAuth()
                        } label: {
                            Label("Request Missing Permissions", systemImage: "lock.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Text("If permissions remain denied after requesting, go to the Simulator's Settings app > Privacy & Security > Health > HealthSeeder and enable each type manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Authorization Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Nuclear Reset Instructions

struct NuclearResetView: View {
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The only way to fully wipe all Apple Health data in the Simulator, including data from other sources, is to erase the entire Simulator. This takes about 10 seconds and only affects this Simulator device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } header: {
                    Label("Why this is needed", systemImage: "info.circle")
                }

                Section("Option 1, Simulator menu (fastest)") {
                    step(number: "1", text: "Bring the Simulator window to focus")
                    step(number: "2", text: "In the menu bar: Device > Erase All Content and Settings")
                    step(number: "3", text: "Confirm in the dialog")
                    step(number: "4", text: "Wait for the Simulator to reboot, then re-run HealthSeeder from Xcode")
                }

                Section("Option 2, Terminal") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run this command to erase the currently booted Simulator:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("xcrun simctl erase booted")
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Label("The \"Delete All Seeded Data\" button removes only samples written by HealthSeeder. Data injected by the Simulator itself (default weight, height, etc.) cannot be deleted by any third-party app.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Full Health Reset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.orange)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
