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

    // MARK: - Auth

    func requestAuth() async {
        // State of Mind requires a separate auth call — mixing it with other types
        // causes batch timeouts on iOS 26.
        if #available(iOS 18.0, *) {
            do {
                try await store.requestAuthorization(toShare: [HKObjectType.stateOfMindType()], read: [])
            } catch {
                // Non-fatal — continue with other types
                print("HealthSeeder: State of Mind auth failed — \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // Request remaining types in small batches with a delay between each
        // to prevent the HealthKit permission dialog from overlapping itself.
        let quantityAndOtherTypes = allTypesToWrite.filter { type in
            if #available(iOS 18.0, *) {
                return type != HKObjectType.stateOfMindType()
            }
            return true
        }
        let allTypes = Array(quantityAndOtherTypes)
        let batchSize = 8
        var index = 0
        while index < allTypes.count {
            let batch = Set(allTypes[index..<min(index + batchSize, allTypes.count)])
            do {
                try await store.requestAuthorization(toShare: batch, read: [])
            } catch {
                authError = error.localizedDescription
                return
            }
            index += batchSize
            if index < allTypes.count {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
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
                print("HealthSeeder: category \(categories[i].name) failed — \(error)")
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
        case 3:  return try await seedBodyMeasurements()
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

        // deleteObjects(of:predicate:) is the most reliable delete API —
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

    private func save(_ samples: [HKSample]) async throws {
        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    private func randomBetween(_ lo: Double, _ hi: Double) -> Double {
        Double.random(in: lo...hi)
    }

    private func quantitySample(type id: HKQuantityTypeIdentifier, quantity: HKQuantity, start: Date, end: Date? = nil) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id), quantity: quantity, start: start, end: end ?? start)
    }

    // MARK: - Activity

    func seedActivity() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            let totalSteps = Int(randomBetween(4000, 14000))
            let stepBuckets = distributeSteps(totalSteps, over: dayStart)
            for (start, steps) in stepBuckets {
                let q = HKQuantity(unit: .count(), doubleValue: Double(steps))
                samples.append(quantitySample(type: .stepCount, quantity: q, start: start, end: start.addingTimeInterval(3600)))
            }

            let distance = Double(totalSteps) * randomBetween(0.0007, 0.0009) * 1000
            samples.append(quantitySample(type: .distanceWalkingRunning, quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: dayStart, end: dayStart.addingTimeInterval(86400)))
            samples.append(quantitySample(type: .activeEnergyBurned, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(200, 900)), start: dayStart, end: dayStart.addingTimeInterval(86400)))
            samples.append(quantitySample(type: .basalEnergyBurned, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(1400, 1900)), start: dayStart, end: dayStart.addingTimeInterval(86400)))

            let flights = Int(randomBetween(0, 25))
            if flights > 0 {
                samples.append(quantitySample(type: .flightsClimbed, quantity: HKQuantity(unit: .count(), doubleValue: Double(flights)), start: dayStart, end: dayStart.addingTimeInterval(86400)))
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

            // Heart Rate Recovery — recorded ~1 min after a workout ends
            // Typical HRR: 12–40 bpm drop in first minute post-exercise
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
    // The cursor advances strictly forward — no gaps, no overlaps guaranteed.

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

            let totalSleepMinutes = Int.random(in: 380...510) // ~6.5–8.5 h

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
            // Clamp duration so we never exceed the total — this is the key fix for overlaps
            let maxAllowed = min(range.upperBound, remaining)
            let minAllowed = min(range.lowerBound, maxAllowed)
            let duration = Int.random(in: minAllowed...maxAllowed)

            let blockEnd = cursor.addingTimeInterval(Double(duration) * 60)
            result.append((cursor, blockEnd, stage))

            // Advance cursor — next block starts exactly where this one ended
            cursor = blockEnd
            remaining -= duration
            patternIndex += 1
        }

        return result
    }

    // MARK: - Body Measurements

    func seedBodyMeasurements() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        var weight = randomBetween(70, 90)
        let height = randomBetween(165, 185)
        let bodyFat = randomBetween(12, 28)

        samples.append(quantitySample(type: .height, quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: height), start: Date().addingTimeInterval(-Double(days) * 86400)))

        for dayOffset in stride(from: 0, to: days, by: 3) {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: day)!

            weight = max(60, min(120, weight + Double.random(in: -0.3...0.3)))
            let bmi = weight / pow(height / 100, 2)
            let lean = weight * (1 - bodyFat / 100)

            samples.append(quantitySample(type: .bodyMass, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: weight), start: ts))
            samples.append(quantitySample(type: .bodyMassIndex, quantity: HKQuantity(unit: .count(), doubleValue: bmi), start: ts))
            samples.append(quantitySample(type: .bodyFatPercentage, quantity: HKQuantity(unit: .percent(), doubleValue: bodyFat / 100), start: ts))
            samples.append(quantitySample(type: .leanBodyMass, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: lean), start: ts))
            samples.append(quantitySample(type: .waistCircumference, quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: randomBetween(76, 94)), start: ts))
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Nutrition
    // Single daily entry with ALL nutritional types at realistic DRI-aligned values.
    // No separate vitamins category to avoid double-counting.

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
                // Fluids & electrolytes
                (.dietaryWater,                  randomBetween(1500, 2500), .literUnit(with: .milli)),
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

        for dayOffset in 0..<days {
            guard dayOffset % 2 == 0 || Bool.random() else { continue }
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let hour = Int.random(in: 6...19)
            let workoutStart = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...30), second: 0, of: day)!

            // ~50% of workouts are running with granular samples; rest are other activities
            let isRunning = Double.random(in: 0...1) < 0.55

            if isRunning {
                // Granular running workout — 40–60 min
                let durationMin = Int.random(in: 40...60)
                let workoutEnd = workoutStart.addingTimeInterval(TimeInterval(durationMin * 60))

                // Full profile (HR + distance) or basic (HR only) — 55/45 split
                let includeDistance = Double.random(in: 0...1) < 0.55

                let totalIntervals = Int(workoutEnd.timeIntervalSince(workoutStart) / intervalSec)
                var samples: [HKSample] = []

                // Granular HR every 10 s — first half ~145 bpm, second half ~155 bpm
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

                // Active energy for full window
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(350, 600)),
                    start: workoutStart, end: workoutEnd
                ))

                // Recovery HR tail — 2 min after workout, falls from ~150 to ~110 bpm
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
                config.locationType = .outdoor
                let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: watchDevice)
                try await builder.beginCollection(at: workoutStart)
                try await builder.addSamples(samples)
                try await builder.endCollection(at: recoveryEnd)
                _ = try await builder.finishWorkout()

            } else {
                // Basic workout — other activity types, single-sample approach
                let workoutType = nonRunningTypes.randomElement()!
                let duration = TimeInterval(Int.random(in: 20...90) * 60)
                let workoutEnd = workoutStart.addingTimeInterval(duration)

                let config = HKWorkoutConfiguration()
                config.activityType = workoutType
                let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
                try await builder.beginCollection(at: workoutStart)

                let aeSample = HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(150, 500)),
                    start: workoutStart, end: workoutEnd
                )
                try await builder.addSamples([aeSample])

                if workoutType == .cycling {
                    let dist = randomBetween(5000, 40000)
                    let dSample = HKQuantitySample(
                        type: HKQuantityType(.distanceWalkingRunning),
                        quantity: HKQuantity(unit: .meter(), doubleValue: dist),
                        start: workoutStart, end: workoutEnd
                    )
                    try await builder.addSamples([dSample])
                }

                try await builder.endCollection(at: workoutEnd)
                _ = try await builder.finishWorkout()
            }

            count += 1
        }

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

    func seedMenstrualCycle() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let flowType = HKCategoryType(.menstrualFlow)
        var currentDay = 0

        while currentDay < days {
            let cycleLength = Int.random(in: 26...32)
            let periodLength = Int.random(in: 3...6)

            for d in 0..<periodLength {
                let day = calendar.date(byAdding: .day, value: -(currentDay + d), to: Date())!
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
            print("HealthSeeder: State of Mind skipped — requires iOS 18+")
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

        // Start at dayOffset 2 — never today (0) or yesterday (1)
        let startOffset = max(days - 1, 2)
        let endOffset = 2

        for dayOffset in stride(from: startOffset, through: endOffset, by: -1) {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            // 1–3 momentary emotion checks throughout the day
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
                    print("HealthSeeder: State of Mind momentaryEmotion save failed — \(error)")
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
                print("HealthSeeder: State of Mind dailyMood save failed — \(error)")
                throw error
            }
        }

        return count
    }
}
