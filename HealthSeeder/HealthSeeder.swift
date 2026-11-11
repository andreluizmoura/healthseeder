//
//  HealthSeeder.swift
//  HealthSeeder
//
//  Phase 2 data change:
//    - New categories: Alcohol (21) and Physical Effort (22). Their code
//      lives in HealthSeeder+NewTypes.swift.
//    - Workouts now carry running form samples (runs), power and cadence on
//      about 70% of rides, a user effort rating on about 60% of workouts
//      (iOS 18) and an FTP sample every 30 days.
//    - The new types are requested in requestNewTypesAuth(). Apple only
//      types (notifications, Breathing Disturbances, AFib History, estimated
//      effort) are never requested: asking to share them raises an
//      exception Swift cannot catch and the app crashes.
//    - Delete All Seeded Data also removes every new type.
//    - walkingAsymmetryPercentage is NOT seeded: apps cannot write it
//      (confirmed: authorization raises an uncatchable exception).
//    - Blood pressure systolic and diastolic are always requested in the
//      same authorization batch.
//
//  Hourly activity change:
//    Steps, distance, active energy, basal energy and flights are written as
//    short samples through the day instead of one sample spanning 24 hours.
//    HealthKit splits a whole day sample evenly across every hour, which made
//    every hourly chart flat in the Simulator. On today, nothing is written
//    for hours that have not started yet. Run Delete All Seeded Data before
//    seeding again, or the old whole day samples stay and add to the new ones.
//

import Foundation
import HealthKit
import Combine

// MARK: - Data Categories

struct SeedCategory {
    let name: String
    let icon: String
    var status: SeedStatus = .pending
    var count: Int = 0
}

enum SeedStatus {
    case pending, running, done, failed
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Seeding..."
        case .done:    return "Done"
        case .failed:  return "Failed"
        }
    }
}

// MARK: - Workout profile

/// Per-activity parameters used to generate realistic non-running workouts.
private struct WorkoutProfile {
    let minutes: ClosedRange<Int>
    /// Steady-state heart rate the workout settles at after warm-up.
    let hrBase: Double
    let kcalPerMinute: ClosedRange<Double>
    /// Average speed in m/s, only for activities that record distance.
    let speed: ClosedRange<Double>?
    let distanceType: HKQuantityTypeIdentifier?
    let location: HKWorkoutSessionLocationType
}

// MARK: - Seeder

@MainActor
class HealthSeeder: ObservableObject {
    let store = HKHealthStore()

    @Published var categories: [SeedCategory] = [
        SeedCategory(name: "Activity & Steps",          icon: "figure.walk"),        // 0
        SeedCategory(name: "Heart Rate",                icon: "heart.fill"),         // 1
        SeedCategory(name: "Sleep",                     icon: "moon.fill"),          // 2
        SeedCategory(name: "Body Measurements",         icon: "scalemass.fill"),     // 3
        SeedCategory(name: "Nutrition",                 icon: "fork.knife"),         // 4
        SeedCategory(name: "Hydration",                 icon: "drop.fill"),          // 5
        SeedCategory(name: "Workouts",                  icon: "dumbbell.fill"),      // 6
        SeedCategory(name: "Blood Oxygen",              icon: "lungs.fill"),         // 7
        SeedCategory(name: "Blood Glucose",             icon: "cross.vial.fill"),    // 8
        SeedCategory(name: "Blood Pressure",            icon: "waveform.path.ecg"),  // 9
        SeedCategory(name: "Body Temperature",          icon: "thermometer.medium"), // 10
        SeedCategory(name: "Respiration",               icon: "wind"),               // 11
        SeedCategory(name: "Mindfulness",               icon: "brain.head.profile"), // 12
        SeedCategory(name: "Menstrual Cycle",           icon: "calendar.badge.clock"),// 13
        SeedCategory(name: "Hearing",                   icon: "ear.fill"),           // 14
        SeedCategory(name: "Reproductive Health",       icon: "staroflife.fill"),    // 15
        SeedCategory(name: "Lab Results",               icon: "testtube.2"),         // 16
        SeedCategory(name: "Walking Metrics",           icon: "figure.walk.motion"), // 17
        SeedCategory(name: "Wrist Temp (system-only)",  icon: "thermometer.sun.fill"),// 18
        SeedCategory(name: "Daylight Exposure",         icon: "sun.max.fill"),       // 19
        SeedCategory(name: "State of Mind",             icon: "face.smiling"),       // 20
        SeedCategory(name: "Alcohol",                   icon: "wineglass.fill"),     // 21
        SeedCategory(name: "Physical Effort",           icon: "flame.fill"),         // 22
    ]

    @Published var isRunning = false
    @Published var isComplete = false
    @Published var isDeleting = false
    @Published var isCheckingAuth = false
    @Published var overallProgress: Double = 0
    @Published var authError: String? = nil
    @Published var deleteResult: DeleteResult? = nil
    @Published var authStatusSummary: AuthStatusSummary? = nil
    @Published var showResetInstructions = false
    @Published var days: Int = 365

    /// Which Weight Patterns analysis state the generated body-mass series
    /// should drive the feature to. Bound to the picker in ContentView.
    /// Defaults to established (the richest case) so an unconfigured run still
    /// shows the full feature.
    @Published var selectedWeightProfile: WeightProfile = .established

    /// Day offsets (counting back from today) of the FIRST day of each period
    /// written by seedMenstrualCycle. seedReproductiveData uses them to anchor
    /// ovulation tests and spotting to the same cycles. Menstrual Cycle (13)
    /// always runs before Reproductive Health (15) in seedAll.
    private var periodStartOffsets: [Int] = []

    var todayOnly: Bool { days == 1 }

    enum DeleteResult {
        case success(Int)
        case failure(String)
    }

    struct AuthStatusSummary {
        let authorized: Int
        let denied: Int
        let notDetermined: Int
        let total: Int
        var denied_names: [String]
        var notDetermined_names: [String]
    }

    // MARK: - All writable types (flat list reused for auth + delete)

    var allQuantityTypes: [HKQuantityTypeIdentifier] {
        [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .basalEnergyBurned, .flightsClimbed,
            .distanceCycling, .distanceSwimming,
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max,
            .bodyMass, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass, .height, .waistCircumference,
            // Macros
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
            .dietaryFatSaturated, .dietaryFatMonounsaturated, .dietaryFatPolyunsaturated,
            .dietaryFiber, .dietarySugar, .dietaryCholesterol,
            // Hydration
            .dietaryWater, .dietarySodium, .dietaryPotassium, .dietaryChloride,
            // Fat-soluble vitamins
            .dietaryVitaminA, .dietaryVitaminD, .dietaryVitaminE, .dietaryVitaminK,
            // Water-soluble vitamins
            .dietaryVitaminC, .dietaryVitaminB6, .dietaryVitaminB12,
            .dietaryThiamin, .dietaryRiboflavin, .dietaryNiacin,
            .dietaryPantothenicAcid, .dietaryBiotin, .dietaryFolate,
            // Minerals
            .dietaryCalcium, .dietaryIron, .dietaryMagnesium, .dietaryZinc,
            .dietaryPhosphorus, .dietaryCopper, .dietaryManganese,
            .dietarySelenium, .dietaryIodine, .dietaryChromium, .dietaryMolybdenum,
            // Caffeine
            .dietaryCaffeine,
            // Vitals
            .oxygenSaturation, .bloodGlucose, .bloodPressureSystolic, .bloodPressureDiastolic,
            .bodyTemperature, .respiratoryRate, .peripheralPerfusionIndex,
            .heartRateRecoveryOneMinute,
            .environmentalAudioExposure, .headphoneAudioExposure,
            .basalBodyTemperature,
            .walkingSpeed, .walkingStepLength, .walkingDoubleSupportPercentage,
            .stairAscentSpeed, .stairDescentSpeed,
            .timeInDaylight,
        ]
    }

    var allCategoryTypeIdentifiers: [HKCategoryTypeIdentifier] {
        [.sleepAnalysis, .mindfulSession, .menstrualFlow, .cervicalMucusQuality,
         .ovulationTestResult, .intermenstrualBleeding]
    }

    var allTypesToWrite: Set<HKSampleType> {
        var types: Set<HKSampleType> = Set(allQuantityTypes.compactMap { HKQuantityType.quantityType(forIdentifier: $0) })
        for id in allCategoryTypeIdentifiers { types.insert(HKCategoryType(id)) }
        types.insert(HKWorkoutType.workoutType())
        if #available(iOS 18.0, *) {
            types.insert(HKObjectType.stateOfMindType())
        }
        return types
    }

    @Published var failedCount: Int = 0

    /// Authorization batches that failed in the last requestAuth run.
    private var failedAuthBatches = 0

    // MARK: - Auth

    /// Pinned to the main thread: from iOS 26 the authorization sheet is only
    /// presented from the main thread, and a request made elsewhere fails
    /// with "Authorization session timed out".
    @MainActor
    func requestAuth() async {
        failedAuthBatches = 0
        // State of Mind requires a separate auth call; mixing it with other types
        // causes batch timeouts on iOS 26.
        if #available(iOS 18.0, *) {
            do {
                try await store.requestAuthorization(toShare: [HKObjectType.stateOfMindType()], read: [])
            } catch {
                // Non-fatal, continue with other types
                print("HealthSeeder: State of Mind auth failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // Phase 2 types: requested apart from the batches below, so a type
        // that apps cannot write never blocks the rest.
        await requestNewTypesAuth()

        // Request remaining types in small batches with a delay between each
        // to prevent the HealthKit permission dialog from overlapping itself.
        let quantityAndOtherTypes = allTypesToWrite.filter { type in
            if #available(iOS 18.0, *) {
                return type != HKObjectType.stateOfMindType()
            }
            return true
        }
        // Blood pressure systolic and diastolic go first, in the same batch:
        // HealthKit expects both together and warns ("did not pass in both
        // blood pressure types") when a batch carries only one of them.
        let bloodPressure: [HKSampleType] = [
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic)
        ]
        let allTypes = bloodPressure + quantityAndOtherTypes.filter { !bloodPressure.contains($0) }
        let batchSize = 8
        var index = 0
        while index < allTypes.count {
            let batch = Set(allTypes[index..<min(index + batchSize, allTypes.count)])
            do {
                try await store.requestAuthorization(toShare: batch, read: [])
            } catch {
                // A timed out batch must not stop the others. Its types show
                // up in Check Permissions and can be requested again there.
                print("HealthSeeder: authorization batch failed: \(error)")
                failedAuthBatches += 1
            }
            index += batchSize
            if index < allTypes.count {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }

        if failedAuthBatches > 0 {
            authError = "\(failedAuthBatches) permission request(s) did not complete. Tap Check Permissions, then Request Missing Permissions."
        }
    }

    // MARK: - Seed All

    func seedAll() async {
        isRunning = true
        isComplete = false
        overallProgress = 0
        failedCount = 0
        let total = Double(categories.count)

        for i in categories.indices {
            categories[i].status = .running
            do {
                let count = try await seedCategory(index: i)
                categories[i].count = count
                categories[i].status = .done
            } catch {
                categories[i].status = .failed
                failedCount += 1
                print("HealthSeeder: category \(categories[i].name) failed: \(error)")
            }
            overallProgress = Double(i + 1) / total
        }

        isRunning = false
        isComplete = true
    }

    private func seedCategory(index: Int) async throws -> Int {
        switch index {
        case 0:  return try await seedActivity()
        case 1:  return try await seedHeartRate()
        case 2:  return try await seedSleep()
        case 3:  return try await seedBodyMeasurementsForProfile()
        case 4:  return try await seedNutrition()
        case 5:  return try await seedHydration()
        case 6:  return try await seedWorkouts()
        case 7:  return try await seedBloodOxygen()
        case 8:  return try await seedBloodGlucose()
        case 9:  return try await seedBloodPressure()
        case 10: return try await seedBodyTemperature()
        case 11: return try await seedRespiration()
        case 12: return try await seedMindfulness()
        case 13: return try await seedMenstrualCycle()
        case 14: return try await seedHearing()
        case 15: return try await seedReproductiveData()
        case 16: return try await seedLaboratory()
        case 17: return try await seedWalkingMetrics()
        case 18: return try await seedWristTemperature()
        case 19: return try await seedDaylight()
        case 20: return try await seedStateOfMind()
        case 21: return try await seedAlcohol()
        case 22: return try await seedPhysicalEffort()
        default: return 0
        }
    }

    func checkAuthStatus() async {
        isCheckingAuth = true
        var authorized = 0
        var denied = 0
        var notDetermined = 0
        var deniedNames: [String] = []
        var notDeterminedNames: [String] = []

        for id in allQuantityTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized:
                authorized += 1
            case .sharingDenied:
                denied += 1
                deniedNames.append(id.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: ""))
            case .notDetermined:
                notDetermined += 1
                notDeterminedNames.append(id.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: ""))
            @unknown default:
                notDetermined += 1
            }
        }

        for id in allCategoryTypeIdentifiers {
            let type = HKCategoryType(id)
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized:
                authorized += 1
            case .sharingDenied:
                denied += 1
                deniedNames.append(id.rawValue.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""))
            case .notDetermined:
                notDetermined += 1
                notDeterminedNames.append(id.rawValue.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""))
            @unknown default:
                notDetermined += 1
            }
        }

        let workoutStatus = store.authorizationStatus(for: HKWorkoutType.workoutType())
        switch workoutStatus {
        case .sharingAuthorized: authorized += 1
        case .sharingDenied: denied += 1; deniedNames.append("Workout")
        default: notDetermined += 1; notDeterminedNames.append("Workout")
        }

        authStatusSummary = AuthStatusSummary(
            authorized: authorized,
            denied: denied,
            notDetermined: notDetermined,
            total: authorized + denied + notDetermined,
            denied_names: deniedNames,
            notDetermined_names: notDeterminedNames
        )
        isCheckingAuth = false
    }

    // MARK: - Delete All Seeded Data

    func deleteAllSeededData() async {
        isDeleting = true
        deleteResult = nil

        // deleteObjects(of:predicate:) is the most reliable delete API:
        // it operates server-side in HealthKit and only removes samples
        // that the calling app wrote, with no fetch step required.
        // End date extends slightly into the future so samples created
        // moments ago today (with end timestamps very close to "now") are not excluded.
        let futureEnd = Date().addingTimeInterval(86400)
        let predicate = HKQuery.predicateForSamples(withStart: Date.distantPast, end: futureEnd, options: .strictStartDate)

        var totalDeleted = 0
        var firstError: String? = nil

        // Delete quantity types
        for id in allQuantityTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            do {
                let count = try await store.deleteObjects(of: type, predicate: predicate)
                totalDeleted += count
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // Delete category types
        for id in allCategoryTypeIdentifiers {
            let type = HKCategoryType(id)
            do {
                let count = try await store.deleteObjects(of: type, predicate: predicate)
                totalDeleted += count
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // Delete workouts
        do {
            let count = try await store.deleteObjects(of: HKWorkoutType.workoutType(), predicate: predicate)
            totalDeleted += count
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }

        // Delete Phase 2 types. Errors on types never authorized are ignored.
        for type in newTypesForDelete {
            if let count = try? await store.deleteObjects(of: type, predicate: predicate) {
                totalDeleted += count
            }
        }

        // Delete blood pressure correlations
        do {
            let count = try await store.deleteObjects(of: HKCorrelationType(.bloodPressure), predicate: predicate)
            totalDeleted += count
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }

        isDeleting = false

        if let err = firstError, totalDeleted == 0 {
            deleteResult = .failure(err)
        } else {
            deleteResult = .success(totalDeleted)
            for i in categories.indices {
                categories[i].status = .pending
                categories[i].count = 0
            }
            isComplete = false
        }
    }

    // MARK: - Helpers

    func save(_ samples: [HKSample]) async throws {
        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    func randomBetween(_ lo: Double, _ hi: Double) -> Double {
        Double.random(in: lo...hi)
    }

    func quantitySample(type id: HKQuantityTypeIdentifier, quantity: HKQuantity, start: Date, end: Date? = nil) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id), quantity: quantity, start: start, end: end ?? start)
    }

    // MARK: - Activity
    // Every cumulative type is written as short samples through the day, the
    // way iPhone and Apple Watch record them. A single sample spanning the
    // whole day is split evenly by HealthKit across 24 hours, so every hourly
    // chart would come out flat. On today, nothing is written for hours that
    // have not started yet, and the current hour ends at now.

    func seedActivity() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let now = Date()

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: now)!
            let dayStart = calendar.startOfDay(for: day)

            // Steps: one sample per hour, weighted toward waking hours.
            let totalSteps = Int(randomBetween(4000, 14000))
            let stepBuckets = distributeSteps(totalSteps, over: dayStart)
            let bucketSteps = max(stepBuckets.reduce(0) { $0 + $1.1 }, 1)

            // Distance and active energy follow the steps of each hour, so
            // the three stay consistent with each other hour by hour.
            let strideMeters = randomBetween(0.7, 0.9)
            let activeTotal  = randomBetween(200, 900)

            for (start, steps) in stepBuckets {
                guard start < now, steps > 0 else { continue }
                let end = min(start.addingTimeInterval(3600), now)
                let share = Double(steps) / Double(bucketSteps)

                samples.append(quantitySample(type: .stepCount, quantity: HKQuantity(unit: .count(), doubleValue: Double(steps)), start: start, end: end))
                samples.append(quantitySample(type: .distanceWalkingRunning, quantity: HKQuantity(unit: .meter(), doubleValue: Double(steps) * strideMeters), start: start, end: end))
                samples.append(quantitySample(type: .activeEnergyBurned, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: activeTotal * share), start: start, end: end))
            }

            // Basal energy: one sample per hour with the same rate, since
            // resting energy is close to constant through the day. The
            // current hour gets only the share of the hour already elapsed.
            let basalPerHour = randomBetween(1400, 1900) / 24
            for hour in 0..<24 {
                let start = dayStart.addingTimeInterval(Double(hour) * 3600)
                guard start < now else { break }
                let end = min(start.addingTimeInterval(3600), now)
                let fraction = end.timeIntervalSince(start) / 3600
                samples.append(quantitySample(type: .basalEnergyBurned, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: basalPerHour * fraction), start: start, end: end))
            }

            // Flights: a few short climbs between 7am and 9pm, two to five
            // minutes each, adding up to the day's total.
            let flights = Int(randomBetween(0, 25))
            if flights > 0 {
                let climbs = min(flights, Int.random(in: 2...6))
                let hours  = Array((7...21).shuffled().prefix(climbs))
                let parts  = splitTotal(flights, into: climbs)
                for (hour, count) in zip(hours, parts) {
                    let start = dayStart.addingTimeInterval(Double(hour * 3600 + Int.random(in: 0...50) * 60))
                    let end   = start.addingTimeInterval(Double(Int.random(in: 2...5) * 60))
                    guard end <= now else { continue }
                    samples.append(quantitySample(type: .flightsClimbed, quantity: HKQuantity(unit: .count(), doubleValue: Double(count)), start: start, end: end))
                }
            }
        }

        try await save(samples)
        return samples.count
    }

    private func distributeSteps(_ total: Int, over dayStart: Date) -> [(Date, Int)] {
        let weights: [Double] = [0,0,0,0,0,0.02,0.05,0.10,0.12,0.10,0.08,0.07,0.08,0.07,0.08,0.07,0.05,0.06,0.05,0.04,0.02,0.01,0.01,0]
        return weights.enumerated().compactMap { hour, weight in
            guard weight > 0 else { return nil }
            let steps = Int(Double(total) * weight * Double.random(in: 0.8...1.2))
            let start = dayStart.addingTimeInterval(Double(hour) * 3600)
            return (start, max(steps, 0))
        }
    }

    /// Splits `total` into `parts` whole numbers of at least 1 that add up to
    /// `total`. Callers guarantee `total >= parts`.
    private func splitTotal(_ total: Int, into parts: Int) -> [Int] {
        guard parts > 0 else { return [] }
        var result = Array(repeating: 1, count: parts)
        for _ in 0..<max(total - parts, 0) {
            result[Int.random(in: 0..<parts)] += 1
        }
        return result
    }

    // MARK: - Heart Rate

    func seedHeartRate() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for hour in 0..<24 {
                for r in 0..<Int.random(in: 1...3) {
                    let ts = dayStart.addingTimeInterval(Double(hour * 3600 + Int.random(in: 0...59) * 60 + r * 300))
                    let bpm: Double = hour >= 1 && hour <= 5 ? randomBetween(48, 62) :
                                      hour >= 6 && hour <= 8 ? randomBetween(65, 85) :
                                      randomBetween(60, 100)
                    samples.append(quantitySample(type: .heartRate, quantity: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: bpm), start: ts))
                }
            }

            samples.append(quantitySample(type: .restingHeartRate, quantity: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: randomBetween(50, 72)), start: dayStart.addingTimeInterval(28800)))
            samples.append(quantitySample(type: .heartRateVariabilitySDNN, quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: randomBetween(20, 80)), start: dayStart.addingTimeInterval(25200)))

            // Heart Rate Recovery: recorded ~1 min after a workout ends.
            // Typical HRR: 12 to 40 bpm drop in first minute post-exercise.
            if dayOffset % 2 == 0 {
                let workoutEndHour = Int.random(in: 14...19)
                let recoveryTs = dayStart.addingTimeInterval(Double(workoutEndHour * 3600 + 60))
                let q = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: randomBetween(12, 40))
                samples.append(quantitySample(type: .heartRateRecoveryOneMinute, quantity: q, start: recoveryTs, end: recoveryTs.addingTimeInterval(60)))
            }

            if dayOffset % 7 == 0 {
                samples.append(quantitySample(type: .vo2Max, quantity: HKQuantity(unit: HKUnit(from: "ml/kg*min"), doubleValue: randomBetween(35, 55)), start: dayStart.addingTimeInterval(36000)))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Sleep
    // Each night is a single continuous chain of sequential, non-overlapping stage blocks.
    // The cursor advances strictly forward: no gaps, no overlaps guaranteed.

    func seedSleep() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let sleepType = HKCategoryType(.sleepAnalysis)

        for dayOffset in 0..<days {
            // `day` represents the night that ENDS on this calendar day (wake-up day).
            // Bedtime is therefore on the PREVIOUS calendar day, never extending past `day` itself.
            // This guarantees sleep data never bleeds into a future, not-yet-seeded day.
            let wakeDay = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let previousNight = calendar.date(byAdding: .day, value: -1, to: wakeDay)!

            let bedtimeHour = Int.random(in: 22...23)
            let bedtimeMinute = Int.random(in: 0...59)
            guard let bedtime = calendar.date(bySettingHour: bedtimeHour, minute: bedtimeMinute, second: 0, of: previousNight) else { continue }

            let totalSleepMinutes = Int.random(in: 380...510) // ~6.5 to 8.5 h

            // Build a strictly sequential chain of stage blocks
            let blocks = buildSleepChain(startingAt: bedtime, totalMinutes: totalSleepMinutes)

            for (blockStart, blockEnd, stage) in blocks {
                samples.append(HKCategorySample(
                    type: sleepType,
                    value: stage.rawValue,
                    start: blockStart,
                    end: blockEnd
                ))
            }
        }

        try await save(samples)
        return samples.count
    }

    /// Produces a chain of (start, end, stage) tuples that are:
    /// - strictly sequential (end of block N == start of block N+1)
    /// - non-overlapping by construction
    /// - covering exactly `totalMinutes` from `startingAt`
    private func buildSleepChain(startingAt bedtime: Date, totalMinutes: Int) -> [(Date, Date, HKCategoryValueSleepAnalysis)] {

        // Realistic 90-min NREM/REM cycle pattern repeated through the night
        // Earlier cycles: more deep sleep. Later cycles: more REM.
        let cyclePattern: [HKCategoryValueSleepAnalysis] = [
            .asleepCore, .asleepDeep, .asleepCore, .asleepREM,
            .asleepCore, .asleepDeep, .asleepCore, .asleepREM,
            .asleepCore,              .asleepCore, .asleepREM,
            .awake,
            .asleepCore,                           .asleepREM,
            .awake,
        ]

        let durationRange: [HKCategoryValueSleepAnalysis: ClosedRange<Int>] = [
            .asleepCore: 18...45,
            .asleepDeep: 10...35,
            .asleepREM:  12...40,
            .awake:       2...6,
        ]

        var result: [(Date, Date, HKCategoryValueSleepAnalysis)] = []
        var cursor = bedtime
        var remaining = totalMinutes
        var patternIndex = 0

        while remaining > 0 {
            let stage = cyclePattern[patternIndex % cyclePattern.count]
            let range = durationRange[stage] ?? 20...40
            // Clamp duration so we never exceed the total; this is the key fix for overlaps
            let maxAllowed = min(range.upperBound, remaining)
            let minAllowed = min(range.lowerBound, maxAllowed)
            let duration = Int.random(in: minAllowed...maxAllowed)

            let blockEnd = cursor.addingTimeInterval(Double(duration) * 60)
            result.append((cursor, blockEnd, stage))

            // Advance cursor: next block starts exactly where this one ended
            cursor = blockEnd
            remaining -= duration
            patternIndex += 1
        }

        return result
    }

    // MARK: - Body Measurements
    // The random-walk seedBodyMeasurements has been replaced by the
    // deterministic seedBodyMeasurementsForProfile in
    // HealthSeeder+WeightProfiles.swift, which the seedCategory switch (case 3)
    // now calls. This method is kept out of the pipeline; it can be deleted.

    // MARK: - Nutrition
    // Single daily entry with ALL nutritional types at realistic DRI-aligned values.
    // No separate vitamins category to avoid double-counting.
    // Water is NOT written here: it lives only in seedHydration, so the daily
    // water total is not doubled.

    func seedNutrition() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)
            let mealStart = dayStart.addingTimeInterval(28800)  // 8am
            let mealEnd   = dayStart.addingTimeInterval(72000)  // 8pm

            let nutrition: [(HKQuantityTypeIdentifier, Double, HKUnit)] = [
                // Macros
                (.dietaryEnergyConsumed,         randomBetween(1800, 2400), .kilocalorie()),
                (.dietaryProtein,                randomBetween(50, 100),    .gram()),
                (.dietaryCarbohydrates,          randomBetween(200, 300),   .gram()),
                (.dietaryFatTotal,               randomBetween(50, 80),     .gram()),
                (.dietaryFatSaturated,           randomBetween(10, 22),     .gram()),
                (.dietaryFatMonounsaturated,     randomBetween(15, 30),     .gram()),
                (.dietaryFatPolyunsaturated,     randomBetween(8, 20),      .gram()),
                (.dietaryFiber,                  randomBetween(20, 35),     .gram()),
                (.dietarySugar,                  randomBetween(25, 50),     .gram()),
                (.dietaryCholesterol,            randomBetween(150, 300),   .gramUnit(with: .milli)),
                // Electrolytes
                (.dietarySodium,                 randomBetween(1200, 2300), .gramUnit(with: .milli)),
                (.dietaryPotassium,              randomBetween(2600, 3500), .gramUnit(with: .milli)),
                (.dietaryChloride,               randomBetween(1800, 2300), .gramUnit(with: .milli)),
                // Fat-soluble vitamins
                (.dietaryVitaminA,               randomBetween(600, 900),   .gramUnit(with: .micro)),
                (.dietaryVitaminD,               randomBetween(10, 20),     .gramUnit(with: .micro)),
                (.dietaryVitaminE,               randomBetween(12, 15),     .gramUnit(with: .milli)),
                (.dietaryVitaminK,               randomBetween(80, 120),    .gramUnit(with: .micro)),
                // Water-soluble vitamins
                (.dietaryVitaminC,               randomBetween(65, 90),     .gramUnit(with: .milli)),
                (.dietaryVitaminB6,              randomBetween(1.0, 1.7),   .gramUnit(with: .milli)),
                (.dietaryVitaminB12,             randomBetween(1.8, 2.4),   .gramUnit(with: .micro)),
                (.dietaryThiamin,                randomBetween(1.0, 1.2),   .gramUnit(with: .milli)),
                (.dietaryRiboflavin,             randomBetween(1.0, 1.3),   .gramUnit(with: .milli)),
                (.dietaryNiacin,                 randomBetween(12, 16),     .gramUnit(with: .milli)),
                (.dietaryPantothenicAcid,        randomBetween(4, 5),       .gramUnit(with: .milli)),
                (.dietaryBiotin,                 randomBetween(25, 30),     .gramUnit(with: .micro)),
                (.dietaryFolate,                 randomBetween(320, 400),   .gramUnit(with: .micro)),
                // Minerals
                (.dietaryCalcium,                randomBetween(900, 1200),  .gramUnit(with: .milli)),
                (.dietaryIron,                   randomBetween(10, 18),     .gramUnit(with: .milli)),
                (.dietaryMagnesium,              randomBetween(280, 420),   .gramUnit(with: .milli)),
                (.dietaryZinc,                   randomBetween(7, 11),      .gramUnit(with: .milli)),
                (.dietaryPhosphorus,             randomBetween(600, 700),   .gramUnit(with: .milli)),
                (.dietaryCopper,                 randomBetween(700, 900),   .gramUnit(with: .micro)),
                (.dietaryManganese,              randomBetween(1.8, 2.3),   .gramUnit(with: .milli)),
                (.dietarySelenium,               randomBetween(45, 55),     .gramUnit(with: .micro)),
                (.dietaryIodine,                 randomBetween(120, 150),   .gramUnit(with: .micro)),
                (.dietaryChromium,               randomBetween(25, 35),     .gramUnit(with: .micro)),
                (.dietaryMolybdenum,             randomBetween(35, 45),     .gramUnit(with: .micro)),
                // Caffeine
                (.dietaryCaffeine,               randomBetween(80, 300),    .gramUnit(with: .milli)),
            ]

            for (id, value, unit) in nutrition {
                samples.append(quantitySample(type: id, quantity: HKQuantity(unit: unit, doubleValue: value), start: mealStart, end: mealEnd))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Hydration
    // The ONLY place dietaryWater is written.

    func seedHydration() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for hour in [7, 9, 11, 13, 15, 17, 19, 21] {
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                samples.append(quantitySample(type: .dietaryWater, quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: randomBetween(150, 400)), start: ts))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Workouts

    /// Realistic duration, intensity, energy and distance per activity.
    private func workoutProfile(for type: HKWorkoutActivityType) -> WorkoutProfile {
        switch type {
        case .walking:
            return WorkoutProfile(minutes: 25...70, hrBase: 108, kcalPerMinute: 4.0...5.5,
                                  speed: 1.2...1.6, distanceType: .distanceWalkingRunning, location: .outdoor)
        case .cycling:
            return WorkoutProfile(minutes: 30...90, hrBase: 138, kcalPerMinute: 8.0...11.0,
                                  speed: 5.5...8.0, distanceType: .distanceCycling, location: .outdoor)
        case .swimming:
            return WorkoutProfile(minutes: 25...60, hrBase: 135, kcalPerMinute: 7.0...10.0,
                                  speed: 0.4...0.6, distanceType: .distanceSwimming, location: .indoor)
        case .functionalStrengthTraining:
            return WorkoutProfile(minutes: 30...60, hrBase: 120, kcalPerMinute: 5.0...7.0,
                                  speed: nil, distanceType: nil, location: .indoor)
        case .yoga:
            return WorkoutProfile(minutes: 20...60, hrBase: 95, kcalPerMinute: 2.5...4.0,
                                  speed: nil, distanceType: nil, location: .indoor)
        case .highIntensityIntervalTraining:
            return WorkoutProfile(minutes: 20...40, hrBase: 150, kcalPerMinute: 10.0...13.0,
                                  speed: nil, distanceType: nil, location: .indoor)
        case .elliptical:
            return WorkoutProfile(minutes: 25...50, hrBase: 135, kcalPerMinute: 7.0...9.0,
                                  speed: nil, distanceType: nil, location: .indoor)
        case .rowing:
            return WorkoutProfile(minutes: 20...45, hrBase: 142, kcalPerMinute: 8.0...10.0,
                                  speed: nil, distanceType: nil, location: .indoor)
        default:
            return WorkoutProfile(minutes: 20...60, hrBase: 125, kcalPerMinute: 5.0...8.0,
                                  speed: nil, distanceType: nil, location: .unknown)
        }
    }

    func seedWorkouts() async throws -> Int {
        let calendar = Calendar.current
        let nonRunningTypes: [HKWorkoutActivityType] = [
            .cycling, .walking, .swimming, .functionalStrengthTraining,
            .yoga, .highIntensityIntervalTraining, .elliptical, .rowing
        ]
        let hrUnit = HKUnit(from: "count/min")
        let intervalSec: TimeInterval = 10

        let watchDevice = HKDevice(
            name: "Apple Watch",
            manufacturer: "Apple Inc.",
            model: "Watch",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )

        var count = 0
        // D5: the most recent run always carries distance (see below).
        var seededRunWithDistance = false

        for dayOffset in 0..<days {
            guard dayOffset % 2 == 0 || Bool.random() else { continue }
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let hour = Int.random(in: 6...19)
            let workoutStart = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...30), second: 0, of: day)!

            // ~55% of workouts are running with granular samples; rest are other activities
            let isRunning = Double.random(in: 0...1) < 0.55

            if isRunning {
                // Granular running workout, 40 to 60 min
                let durationMin = Int.random(in: 40...60)
                let workoutEnd = workoutStart.addingTimeInterval(TimeInterval(durationMin * 60))

                // D5: about 80% of runs carry distance, so pace and splits show.
                // The most recent run always does (days are walked from today
                // back), so the first run in Activities can test pace in km and
                // in miles. The rest are HR only and logged as indoor, like a
                // treadmill run without distance, to keep that path covered.
                let includeDistance = !seededRunWithDistance || Double.random(in: 0...1) < 0.8
                if includeDistance { seededRunWithDistance = true }

                let totalIntervals = Int(workoutEnd.timeIntervalSince(workoutStart) / intervalSec)
                var samples: [HKSample] = []

                // Granular HR every 10 s: first half ~145 bpm, second half ~155 bpm
                var t = workoutStart
                for i in 0..<totalIntervals {
                    let progress = Double(i) / Double(totalIntervals)
                    let base: Double = progress < 0.5 ? 145 : 155
                    let noise = Double.random(in: -8...8)
                    let spike = Bool.random() && Int.random(in: 0...20) == 0 ? Double.random(in: 10...20) : 0
                    let bpm = max(120, min(185, base + noise + spike))
                    samples.append(HKQuantitySample(
                        type: HKQuantityType(.heartRate),
                        quantity: HKQuantity(unit: hrUnit, doubleValue: bpm),
                        start: t, end: t
                    ))
                    t = t.addingTimeInterval(intervalSec)
                }

                // Incremental distance every 10 s summing to ~9 km (scaled to duration)
                if includeDistance {
                    let targetTotal = 9000.0 * Double(durationMin) / 50.0
                    let targetPerInterval = targetTotal / Double(totalIntervals)
                    t = workoutStart
                    for _ in 0..<totalIntervals {
                        let increment = targetPerInterval * Double.random(in: 0.85...1.15)
                        let end = t.addingTimeInterval(intervalSec)
                        samples.append(HKQuantitySample(
                            type: HKQuantityType(.distanceWalkingRunning),
                            quantity: HKQuantity(unit: .meter(), doubleValue: increment),
                            start: t, end: end
                        ))
                        t = end
                    }
                }

                // Running form, one sample per minute (outdoor run).
                samples.append(contentsOf: runningFormSamples(start: workoutStart, minutes: durationMin))

                // Active energy for full window
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(350, 600)),
                    start: workoutStart, end: workoutEnd
                ))

                // Recovery HR tail: 2 min after workout, falls from ~150 to ~110 bpm
                var recoveryBpm = 150.0
                var rt = workoutEnd
                let recoveryEnd = workoutEnd.addingTimeInterval(120)
                while rt < recoveryEnd {
                    recoveryBpm = max(110, recoveryBpm - Double.random(in: 2...5))
                    samples.append(HKQuantitySample(
                        type: HKQuantityType(.heartRate),
                        quantity: HKQuantity(unit: hrUnit, doubleValue: recoveryBpm),
                        start: rt, end: rt
                    ))
                    rt = rt.addingTimeInterval(intervalSec)
                }

                let config = HKWorkoutConfiguration()
                config.activityType = .running
                config.locationType = includeDistance ? .outdoor : .indoor
                let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: watchDevice)
                try await builder.beginCollection(at: workoutStart)
                try await builder.addSamples(samples)
                try await builder.endCollection(at: recoveryEnd)
                let finished = try await builder.finishWorkout()
                if let finished { await relateEffortIfNeeded(to: finished) }

            } else {
                // Non-running workout: HR every 30 s with warm-up, per-minute
                // distance in the activity's own distance type, and energy scaled
                // to duration and intensity. All samples added in one batch.
                let workoutType = nonRunningTypes.randomElement()!
                let profile = workoutProfile(for: workoutType)
                let durationMin = Int.random(in: profile.minutes)
                let duration = TimeInterval(durationMin * 60)
                let workoutEnd = workoutStart.addingTimeInterval(duration)

                var samples: [HKSample] = []

                // Heart rate: 3 min warm-up ramp from ~90 bpm to the activity
                // base, then steady state with noise. HIIT alternates 60 s work
                // (+15 bpm) and 90 s recovery (-12 bpm) after the warm-up.
                let hrInterval: TimeInterval = 30
                let hrSteps = Int(duration / hrInterval)
                for step in 0..<hrSteps {
                    let elapsed = Double(step) * hrInterval
                    let warmUp = min(1.0, elapsed / 180)
                    var target = 90 + (profile.hrBase - 90) * warmUp
                    if workoutType == .highIntensityIntervalTraining && elapsed >= 180 {
                        let phase = (elapsed - 180).truncatingRemainder(dividingBy: 150)
                        target += phase < 60 ? 15 : -12
                    }
                    let bpm = max(70, min(190, target + Double.random(in: -5...5)))
                    let ts = workoutStart.addingTimeInterval(elapsed)
                    samples.append(HKQuantitySample(
                        type: HKQuantityType(.heartRate),
                        quantity: HKQuantity(unit: hrUnit, doubleValue: bpm),
                        start: ts, end: ts
                    ))
                }

                // Distance: one sample per minute in the correct type
                // (distanceCycling for cycling, distanceSwimming for swimming,
                // distanceWalkingRunning for walking), so the workout's total
                // distance is computed correctly by the builder.
                if let distanceId = profile.distanceType, let speedRange = profile.speed {
                    let avgSpeed = Double.random(in: speedRange)
                    for minute in 0..<durationMin {
                        let start = workoutStart.addingTimeInterval(Double(minute) * 60)
                        let meters = avgSpeed * 60 * Double.random(in: 0.85...1.15)
                        samples.append(HKQuantitySample(
                            type: HKQuantityType(distanceId),
                            quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                            start: start, end: start.addingTimeInterval(60)
                        ))
                    }
                }

                // Cycling sensors (power and cadence) on about 70% of rides.
                // The rest stay without a sensor to show the empty line.
                if workoutType == .cycling, Double.random(in: 0...1) < 0.7 {
                    samples.append(contentsOf: cyclingSensorSamples(start: workoutStart, minutes: durationMin))
                }

                // Active energy scaled to duration and activity intensity
                let kcal = Double(durationMin) * Double.random(in: profile.kcalPerMinute)
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                    start: workoutStart, end: workoutEnd
                ))

                let config = HKWorkoutConfiguration()
                config.activityType = workoutType
                config.locationType = profile.location
                if workoutType == .swimming {
                    config.swimmingLocationType = .pool
                    config.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
                }

                let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: watchDevice)
                try await builder.beginCollection(at: workoutStart)
                try await builder.addSamples(samples)
                try await builder.endCollection(at: workoutEnd)
                let finished = try await builder.finishWorkout()
                if let finished { await relateEffortIfNeeded(to: finished) }
            }

            count += 1
        }

        // FTP every 30 days (cycling functional threshold power).
        count += await seedFTP()

        return count
    }

    // MARK: - Blood Oxygen

    func seedBloodOxygen() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for _ in 0..<Int.random(in: 4...8) {
                let ts = dayStart.addingTimeInterval(Double(Int.random(in: 0...86399)))
                samples.append(quantitySample(type: .oxygenSaturation, quantity: HKQuantity(unit: .percent(), doubleValue: randomBetween(0.94, 0.99)), start: ts))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Blood Glucose

    func seedBloodGlucose() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let unit = HKUnit(from: "mg/dL")

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for (hour, value) in [(7, randomBetween(70, 100)), (9, randomBetween(90, 140)),
                                   (12, randomBetween(80, 110)), (14, randomBetween(90, 150)),
                                   (19, randomBetween(80, 110)), (21, randomBetween(90, 140))] {
                samples.append(quantitySample(type: .bloodGlucose, quantity: HKQuantity(unit: unit, doubleValue: value), start: dayStart.addingTimeInterval(Double(hour * 3600))))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Blood Pressure
    // Blood pressure must be saved as an HKCorrelation containing both systolic and diastolic.
    // Saving them as separate HKQuantitySamples triggers the "did not pass in both types" warning.

    func seedBloodPressure() async throws -> Int {
        var correlations: [HKSample] = []
        let calendar = Calendar.current
        let mmHg = HKUnit.millimeterOfMercury()
        let correlationType = HKCorrelationType(.bloodPressure)

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!

            for hour in [7, 13, 19] {
                let ts = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...30), second: 0, of: day)!

                let systolic = HKQuantitySample(
                    type: HKQuantityType(.bloodPressureSystolic),
                    quantity: HKQuantity(unit: mmHg, doubleValue: randomBetween(110, 135)),
                    start: ts, end: ts
                )
                let diastolic = HKQuantitySample(
                    type: HKQuantityType(.bloodPressureDiastolic),
                    quantity: HKQuantity(unit: mmHg, doubleValue: randomBetween(65, 85)),
                    start: ts, end: ts
                )

                let correlation = HKCorrelation(
                    type: correlationType,
                    start: ts,
                    end: ts,
                    objects: [systolic, diastolic]
                )
                correlations.append(correlation)
            }
        }

        try await save(correlations)
        return correlations.count
    }

    // MARK: - Body Temperature

    func seedBodyTemperature() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
            samples.append(quantitySample(type: .bodyTemperature, quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: randomBetween(36.2, 37.2)), start: ts))
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Respiration

    func seedRespiration() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for hour in [8, 12, 16, 20, 23] {
                samples.append(quantitySample(type: .respiratoryRate, quantity: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: randomBetween(12, 20)), start: dayStart.addingTimeInterval(Double(hour * 3600))))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Mindfulness

    func seedMindfulness() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let type = HKCategoryType(.mindfulSession)

        for dayOffset in 0..<days {
            guard dayOffset % 2 == 0 || Bool.random() else { continue }
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = calendar.date(bySettingHour: 7, minute: Int.random(in: 0...30), second: 0, of: day)!
            let duration = TimeInterval(Int.random(in: 5...30) * 60)
            samples.append(HKCategorySample(type: type, value: HKCategoryValue.notApplicable.rawValue, start: ts, end: ts.addingTimeInterval(duration)))
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Menstrual Cycle
    // Cycles are laid out backwards from today. Within each period, d == 0 is
    // the chronologically FIRST day (oldest), which carries the cycle-start
    // flag and the flow pattern runs forward in time from there.

    func seedMenstrualCycle() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let flowType = HKCategoryType(.menstrualFlow)
        var currentDay = 0
        periodStartOffsets = []

        while currentDay < days {
            let cycleLength = Int.random(in: 26...32)
            let periodLength = Int.random(in: 3...6)

            // Offset of the chronologically first day of this period.
            let firstDayOffset = currentDay + periodLength - 1
            periodStartOffsets.append(firstDayOffset)

            for d in 0..<periodLength {
                let day = calendar.date(byAdding: .day, value: -(firstDayOffset - d), to: Date())!
                let dayStart = calendar.startOfDay(for: day)
                let flowValue: HKCategoryValueVaginalBleeding = d == 0 ? .light : d <= 2 ? .medium : .light
                samples.append(HKCategorySample(
                    type: flowType,
                    value: flowValue.rawValue,
                    start: dayStart,
                    end: dayStart.addingTimeInterval(86400),
                    metadata: [HKMetadataKeyMenstrualCycleStart: d == 0]
                ))
            }
            currentDay += cycleLength
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Hearing

    func seedHearing() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let dbUnit = HKUnit.decibelAWeightedSoundPressureLevel()

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for hour in stride(from: 8, to: 22, by: 2) {
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                samples.append(quantitySample(type: .environmentalAudioExposure, quantity: HKQuantity(unit: dbUnit, doubleValue: randomBetween(45, 80)), start: ts, end: ts.addingTimeInterval(7200)))
            }

            if Bool.random() {
                let ts = dayStart.addingTimeInterval(Double(Int.random(in: 10...20) * 3600))
                samples.append(quantitySample(type: .headphoneAudioExposure, quantity: HKQuantity(unit: dbUnit, doubleValue: randomBetween(55, 85)), start: ts, end: ts.addingTimeInterval(3600)))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Reproductive Health

    func seedReproductiveData() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: day)!

            samples.append(HKQuantitySample(type: HKQuantityType(.basalBodyTemperature), quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: randomBetween(36.0, 37.0)), start: ts, end: ts))

            if dayOffset % 3 == 0 {
                let values: [HKCategoryValueCervicalMucusQuality] = [.dry, .sticky, .creamy, .watery, .eggWhite]
                samples.append(HKCategorySample(type: HKCategoryType(.cervicalMucusQuality), value: values.randomElement()!.rawValue, start: ts, end: ts.addingTimeInterval(86400)))
            }
        }

        // Ovulation tests and mid-cycle spotting, anchored to the period first
        // days written by seedMenstrualCycle so they line up with the cycles.
        // Cycle day 1 == the period's first day.
        let ovulationType = HKCategoryType(.ovulationTestResult)
        let spottingType = HKCategoryType(.intermenstrualBleeding)

        for (cycleIndex, startOffset) in periodStartOffsets.enumerated() {
            // Daily tests on cycle days 10 to 16: estrogen surge on 11 and 12,
            // LH surge on 13 and 14, negative otherwise.
            for cycleDay in 10...16 {
                let offset = startOffset - (cycleDay - 1)
                guard offset >= 0, offset < days else { continue }
                let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
                let ts = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!

                let result: HKCategoryValueOvulationTestResult
                switch cycleDay {
                case 11, 12: result = .estrogenSurge
                case 13, 14: result = .luteinizingHormoneSurge
                default:     result = .negative
                }
                samples.append(HKCategorySample(type: ovulationType, value: result.rawValue, start: ts, end: ts))
            }

            // Light ovulation spotting on cycle day 15, roughly one cycle in three.
            if cycleIndex % 3 == 1 {
                let offset = startOffset - 14
                if offset >= 0, offset < days {
                    let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
                    let dayStart = calendar.startOfDay(for: day)
                    samples.append(HKCategorySample(
                        type: spottingType,
                        value: HKCategoryValue.notApplicable.rawValue,
                        start: dayStart,
                        end: dayStart.addingTimeInterval(86400)
                    ))
                }
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Lab Results

    func seedLaboratory() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for monthOffset in 0..<12 {
            guard let day = calendar.date(byAdding: .month, value: -monthOffset, to: Date()) else { continue }
            let ts = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
            samples.append(quantitySample(type: .bloodGlucose, quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: randomBetween(80, 100)), start: ts))
            samples.append(quantitySample(type: .peripheralPerfusionIndex, quantity: HKQuantity(unit: .percent(), doubleValue: randomBetween(0.02, 0.20)), start: ts))
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Walking Metrics

    func seedWalkingMetrics() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            for hour in [9, 11, 14, 17] {
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                let end = ts.addingTimeInterval(600)
                samples.append(quantitySample(type: .walkingSpeed, quantity: HKQuantity(unit: HKUnit(from: "m/s"), doubleValue: randomBetween(1.0, 1.8)), start: ts, end: end))
                samples.append(quantitySample(type: .walkingStepLength, quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: randomBetween(60, 80)), start: ts, end: end))
                samples.append(quantitySample(type: .walkingDoubleSupportPercentage, quantity: HKQuantity(unit: .percent(), doubleValue: randomBetween(0.20, 0.35)), start: ts, end: end))
            }

            if dayOffset % 3 == 0 {
                let ts = dayStart.addingTimeInterval(Double(Int.random(in: 8...18) * 3600))
                let end = ts.addingTimeInterval(30)
                samples.append(quantitySample(type: .stairAscentSpeed, quantity: HKQuantity(unit: HKUnit(from: "m/s"), doubleValue: randomBetween(0.3, 0.8)), start: ts, end: end))
                samples.append(quantitySample(type: .stairDescentSpeed, quantity: HKQuantity(unit: HKUnit(from: "m/s"), doubleValue: randomBetween(0.3, 0.8)), start: ts, end: end))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Wrist Temperature (system-only)

    func seedWristTemperature() async throws -> Int { return 0 }

    // MARK: - Daylight Exposure

    func seedDaylight() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            let blocks = Int.random(in: 1...3)
            let outdoorHours = [9, 12, 16, 18].shuffled().prefix(blocks)
            var remaining = Int(randomBetween(20, 120))

            for hour in outdoorHours {
                guard remaining > 0 else { break }
                let blockMin = min(Int.random(in: 10...45), remaining)
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                let end = ts.addingTimeInterval(Double(blockMin) * 60)
                samples.append(quantitySample(type: .timeInDaylight, quantity: HKQuantity(unit: .minute(), doubleValue: Double(blockMin)), start: ts, end: end))
                remaining -= blockMin
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - State of Mind
    // Requires iOS 18+. Never seeds today or yesterday (dayOffset 0 and 1) regardless
    // of the period selected, so partial-day data doesn't skew correlation analysis.

    func seedStateOfMind() async throws -> Int {
        guard #available(iOS 18.0, *) else {
            print("HealthSeeder: State of Mind skipped, requires iOS 18+")
            return 0
        }

        var count = 0
        let calendar = Calendar.current

        let allLabels: [HKStateOfMind.Label] = [
            .amazed, .amused, .angry, .anxious, .calm, .content,
            .disappointed, .discouraged, .drained, .excited, .frustrated,
            .grateful, .happy, .hopeful, .indifferent, .irritated, .joyful,
            .lonely, .overwhelmed, .peaceful, .proud, .relieved, .sad,
            .satisfied, .stressed, .surprised, .worried,
            .annoyed, .confident, .ashamed, .brave, .disgusted,
            .embarrassed, .guilty, .hopeless, .jealous, .passionate, .scared
        ]

        let allAssociations: [HKStateOfMind.Association] = [
            .community, .currentEvents, .education, .family,
            .fitness, .friends, .health, .hobbies, .identity,
            .money, .partner, .selfCare, .tasks, .travel, .work,
            .dating, .spirituality, .weather
        ]

        // Start at dayOffset 2: never today (0) or yesterday (1)
        let startOffset = max(days - 1, 2)
        let endOffset = 2

        for dayOffset in stride(from: startOffset, through: endOffset, by: -1) {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            // 1 to 3 momentary emotion checks throughout the day
            let momentaryHours = [8, 13, 19].shuffled().prefix(Int.random(in: 1...3))
            for hour in momentaryHours {
                let ts = dayStart.addingTimeInterval(Double(hour * 3600 + Int.random(in: 0...1799)))
                let valence = Double.random(in: -1.0...1.0)
                let labels = Array(allLabels.shuffled().prefix(Int.random(in: 1...4)))
                let associations = Array(allAssociations.shuffled().prefix(Int.random(in: 1...3)))

                do {
                    let sample = HKStateOfMind(
                        date: ts,
                        kind: .momentaryEmotion,
                        valence: valence,
                        labels: labels,
                        associations: associations
                    )
                    try await store.save(sample)
                    count += 1
                } catch {
                    print("HealthSeeder: State of Mind momentaryEmotion save failed: \(error)")
                    throw error
                }
            }

            // 1 daily mood at end of day (.dailyMood = kind rawValue 2)
            let summaryTs = dayStart.addingTimeInterval(Double(Int.random(in: 79200...82800)))
            let summaryValence = Double.random(in: -1.0...1.0)
            let summaryLabels = Array(allLabels.shuffled().prefix(Int.random(in: 2...5)))
            let summaryAssociations = Array(allAssociations.shuffled().prefix(Int.random(in: 1...4)))

            do {
                let summary = HKStateOfMind(
                    date: summaryTs,
                    kind: .dailyMood,
                    valence: summaryValence,
                    labels: summaryLabels,
                    associations: summaryAssociations
                )
                try await store.save(summary)
                count += 1
            } catch {
                print("HealthSeeder: State of Mind dailyMood save failed: \(error)")
                throw error
            }
        }

        return count
    }
}
