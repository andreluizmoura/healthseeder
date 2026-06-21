import SwiftUI

struct ContentView: View {
    @StateObject private var seeder = HealthSeeder()
    @State private var showDeleteConfirmation = false

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
                Text("Injects realistic data into the Simulator's Apple Health for the last \(seeder.days) days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Text("Period:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Days", selection: $seeder.days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days").tag(365)
                }
                .pickerStyle(.segmented)
                .disabled(seeder.isRunning || seeder.isDeleting)
            }
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
                Label("Open the Health app on this Simulator to review the data.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
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

#Preview {
    ContentView()
}
