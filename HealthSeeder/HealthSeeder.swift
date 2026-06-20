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
        SeedCategory(name: "Activity & Steps",           icon: "figure.walk"),
        SeedCategory(name: "Heart Rate",                 icon: "heart.fill"),
        SeedCategory(name: "Sleep",                      icon: "moon.fill"),
        SeedCategory(name: "Body Measurements",          icon: "scalemass.fill"),
        SeedCategory(name: "Nutrition",                  icon: "fork.knife"),
        SeedCategory(name: "Hydration",                  icon: "drop.fill"),
        SeedCategory(name: "Workouts",                   icon: "dumbbell.fill"),
        SeedCategory(name: "Blood Oxygen",               icon: "lungs.fill"),
        SeedCategory(name: "Blood Glucose",              icon: "cross.vial.fill"),
        SeedCategory(name: "Blood Pressure",             icon: "waveform.path.ecg"),
        SeedCategory(name: "Body Temperature",           icon: "thermometer.medium"),
        SeedCategory(name: "Respiration",                icon: "wind"),
        SeedCategory(name: "Mindfulness",                icon: "brain.head.profile"),
        SeedCategory(name: "Menstrual Cycle",            icon: "calendar.badge.clock"),
        SeedCategory(name: "Hearing",                    icon: "ear.fill"),
        SeedCategory(name: "Reproductive Health",        icon: "staroflife.fill"),
        SeedCategory(name: "Vitamins & Supplements",     icon: "pills.fill"),
        SeedCategory(name: "Lab Results",                icon: "testtube.2"),
        SeedCategory(name: "Walking Metrics",            icon: "figure.walk.motion"),
        SeedCategory(name: "Wrist Temp (system-only)",   icon: "thermometer.sun.fill"),
        SeedCategory(name: "Daylight Exposure",          icon: "sun.max.fill"),
    ]

    @Published var isRunning = false
    @Published var isComplete = false
    @Published var overallProgress: Double = 0
    @Published var authError: String? = nil
    @Published var days: Int = 365

    // MARK: - Auth

    var allTypesToWrite: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            // Activity
            .quantityType(forIdentifier: .stepCount)!,
            .quantityType(forIdentifier: .distanceWalkingRunning)!,
            .quantityType(forIdentifier: .activeEnergyBurned)!,
            .quantityType(forIdentifier: .basalEnergyBurned)!,
            .quantityType(forIdentifier: .flightsClimbed)!,

            // Heart
            .quantityType(forIdentifier: .heartRate)!,
            .quantityType(forIdentifier: .restingHeartRate)!,
            .quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            .quantityType(forIdentifier: .vo2Max)!,

            // Body
            .quantityType(forIdentifier: .bodyMass)!,
            .quantityType(forIdentifier: .bodyMassIndex)!,
            .quantityType(forIdentifier: .bodyFatPercentage)!,
            .quantityType(forIdentifier: .leanBodyMass)!,
            .quantityType(forIdentifier: .height)!,
            .quantityType(forIdentifier: .waistCircumference)!,

            // Nutrition
            .quantityType(forIdentifier: .dietaryEnergyConsumed)!,
            .quantityType(forIdentifier: .dietaryProtein)!,
            .quantityType(forIdentifier: .dietaryCarbohydrates)!,
            .quantityType(forIdentifier: .dietaryFatTotal)!,
            .quantityType(forIdentifier: .dietaryFiber)!,
            .quantityType(forIdentifier: .dietaryWater)!,
            .quantityType(forIdentifier: .dietarySodium)!,
            .quantityType(forIdentifier: .dietarySugar)!,
            .quantityType(forIdentifier: .dietaryCholesterol)!,
            .quantityType(forIdentifier: .dietaryVitaminC)!,
            .quantityType(forIdentifier: .dietaryVitaminD)!,
            .quantityType(forIdentifier: .dietaryCalcium)!,
            .quantityType(forIdentifier: .dietaryIron)!,
            .quantityType(forIdentifier: .dietaryMagnesium)!,
            .quantityType(forIdentifier: .dietaryZinc)!,
            .quantityType(forIdentifier: .dietaryPotassium)!,
            .quantityType(forIdentifier: .dietaryVitaminB12)!,
            .quantityType(forIdentifier: .dietaryFolate)!,

            // Vitals
            .quantityType(forIdentifier: .oxygenSaturation)!,
            .quantityType(forIdentifier: .bloodGlucose)!,
            .quantityType(forIdentifier: .bloodPressureSystolic)!,
            .quantityType(forIdentifier: .bloodPressureDiastolic)!,
            .quantityType(forIdentifier: .bodyTemperature)!,
            .quantityType(forIdentifier: .respiratoryRate)!,
            .quantityType(forIdentifier: .peripheralPerfusionIndex)!,

            // Hearing
            .quantityType(forIdentifier: .environmentalAudioExposure)!,
            .quantityType(forIdentifier: .headphoneAudioExposure)!,

            // Reproductive
            .quantityType(forIdentifier: .basalBodyTemperature)!,

            // Walking metrics
            .quantityType(forIdentifier: .walkingSpeed)!,
            .quantityType(forIdentifier: .walkingStepLength)!,
            .quantityType(forIdentifier: .walkingDoubleSupportPercentage)!,
            .quantityType(forIdentifier: .stairAscentSpeed)!,
            .quantityType(forIdentifier: .stairDescentSpeed)!,

            // Daylight
            .quantityType(forIdentifier: .timeInDaylight)!,

            // Workouts
            HKWorkoutType.workoutType(),
        ]

        // Category types
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKCategoryType(.mindfulSession))
        types.insert(HKCategoryType(.menstrualFlow))
        types.insert(HKCategoryType(.cervicalMucusQuality))
        types.insert(HKCategoryType(.ovulationTestResult))
        types.insert(HKCategoryType(.intermenstrualBleeding))

        return types
    }

    func requestAuth() async {
        // iOS times out when requesting too many types at once.
        // Split into batches of 15 and request sequentially.
        let allTypes = Array(allTypesToWrite)
        let batchSize = 15
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
        }
    }

    // MARK: - Seed All

    func seedAll() async {
        isRunning = true
        isComplete = false
        overallProgress = 0
        let total = Double(categories.count)

        for i in categories.indices {
            categories[i].status = .running
            do {
                let count = try await seedCategory(index: i)
                categories[i].count = count
                categories[i].status = .done
            } catch {
                categories[i].status = .failed
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
        case 16: return try await seedVitamins()
        case 17: return try await seedLaboratory()
        case 18: return try await seedWalkingMetrics()
        case 19: return try await seedWristTemperature()
        case 20: return try await seedDaylight()
        default: return 0
        }
    }

    // MARK: - Helpers

    private func save(_ samples: [HKSample]) async throws {
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

            // Steps with hourly distribution
            let totalSteps = Int(randomBetween(4000, 14000))
            let stepBuckets = distributeSteps(totalSteps, over: dayStart)
            for (start, steps) in stepBuckets {
                let q = HKQuantity(unit: .count(), doubleValue: Double(steps))
                samples.append(quantitySample(type: .stepCount, quantity: q, start: start, end: start.addingTimeInterval(3600)))
            }

            // Distance
            let distance = Double(totalSteps) * randomBetween(0.0007, 0.0009) * 1000
            let dq = HKQuantity(unit: .meter(), doubleValue: distance)
            samples.append(quantitySample(type: .distanceWalkingRunning, quantity: dq, start: dayStart, end: dayStart.addingTimeInterval(86400)))

            // Active calories
            let aq = HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(200, 900))
            samples.append(quantitySample(type: .activeEnergyBurned, quantity: aq, start: dayStart, end: dayStart.addingTimeInterval(86400)))

            // Basal calories
            let bq = HKQuantity(unit: .kilocalorie(), doubleValue: randomBetween(1400, 1900))
            samples.append(quantitySample(type: .basalEnergyBurned, quantity: bq, start: dayStart, end: dayStart.addingTimeInterval(86400)))

            // Flights climbed
            let flights = Int(randomBetween(0, 25))
            if flights > 0 {
                let fq = HKQuantity(unit: .count(), doubleValue: Double(flights))
                samples.append(quantitySample(type: .flightsClimbed, quantity: fq, start: dayStart, end: dayStart.addingTimeInterval(86400)))
            }
        }

        try await save(samples)
        return samples.count
    }

    private func distributeSteps(_ total: Int, over dayStart: Date) -> [(Date, Int)] {
        let weights: [Double] = [0,0,0,0,0,0.02,0.05,0.10,0.12,0.10,0.08,0.07,0.08,0.07,0.08,0.07,0.05,0.06,0.05,0.04,0.02,0.01,0.01,0]
        var result: [(Date, Int)] = []
        for (hour, weight) in weights.enumerated() {
            if weight > 0 {
                let steps = Int(Double(total) * weight * Double.random(in: 0.8...1.2))
                let start = dayStart.addingTimeInterval(Double(hour) * 3600)
                result.append((start, max(steps, 0)))
            }
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
                let readingsCount = Int.random(in: 1...3)
                for r in 0..<readingsCount {
                    let minute = Int.random(in: 0...59)
                    let ts = dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60 + r * 300))
                    let bpm: Double
                    if hour >= 1 && hour <= 5 { bpm = randomBetween(48, 62) }
                    else if hour >= 6 && hour <= 8 { bpm = randomBetween(65, 85) }
                    else { bpm = randomBetween(60, 100) }
                    let q = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: bpm)
                    samples.append(quantitySample(type: .heartRate, quantity: q, start: ts))
                }
            }

            // Resting HR
            let rq = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: randomBetween(50, 72))
            samples.append(quantitySample(type: .restingHeartRate, quantity: rq, start: dayStart.addingTimeInterval(28800)))

            // HRV
            let hq = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: randomBetween(20, 80))
            samples.append(quantitySample(type: .heartRateVariabilitySDNN, quantity: hq, start: dayStart.addingTimeInterval(25200)))

            // VO2Max weekly
            if dayOffset % 7 == 0 {
                let vq = HKQuantity(unit: HKUnit(from: "ml/kg*min"), doubleValue: randomBetween(35, 55))
                samples.append(quantitySample(type: .vo2Max, quantity: vq, start: dayStart.addingTimeInterval(36000)))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Sleep

    func seedSleep() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let type = HKCategoryType(.sleepAnalysis)

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            // Bedtime: 10pm–midnight
            let bedtimeHour = Int.random(in: 22...23)
            let bedtime = Calendar.current.date(bySettingHour: bedtimeHour, minute: Int.random(in: 0...59), second: 0, of: day)!
            let totalSleepMin = Int.random(in: 360...510)

            let stageBlocks = generateSleepStages(total: totalSleepMin, start: bedtime)
            for (start, end, value) in stageBlocks {
                samples.append(HKCategorySample(type: type, value: value.rawValue, start: start, end: end))
            }
        }

        try await save(samples)
        return samples.count
    }

    private func generateSleepStages(total: Int, start: Date) -> [(Date, Date, HKCategoryValueSleepAnalysis)] {
        // Realistic cycle: Core -> Deep -> REM -> Core -> brief Awake, repeat
        let cycleOrder: [HKCategoryValueSleepAnalysis] = [
            .asleepCore, .asleepDeep, .asleepREM, .asleepCore, .awake
        ]
        let durationRanges: [HKCategoryValueSleepAnalysis: ClosedRange<Int>] = [
            .asleepCore: 20...50,
            .asleepDeep: 10...40,
            .asleepREM:  15...45,
            .awake:       2...8,
        ]
        var result: [(Date, Date, HKCategoryValueSleepAnalysis)] = []
        var cursor = start
        var remaining = total
        var cycleIndex = 0

        while remaining > 0 {
            let stage = cycleOrder[cycleIndex % cycleOrder.count]
            let range = durationRanges[stage] ?? 20...40
            let duration = min(Int.random(in: range), remaining)
            let end = cursor.addingTimeInterval(Double(duration) * 60)
            result.append((cursor, end, stage))
            cursor = end
            remaining -= duration
            cycleIndex += 1
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

        let hq = HKQuantity(unit: .meterUnit(with: .centi), doubleValue: height)
        samples.append(quantitySample(type: .height, quantity: hq, start: Date().addingTimeInterval(-Double(days) * 86400)))

        for dayOffset in stride(from: 0, to: days, by: 3) {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: day)!

            weight += Double.random(in: -0.3...0.3)
            weight = max(60, min(120, weight))

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

    func seedNutrition() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)
            let mealStart = dayStart.addingTimeInterval(43200)
            let mealEnd = dayStart.addingTimeInterval(75600)

            let nutrition: [(HKQuantityTypeIdentifier, Double, HKUnit)] = [
                (.dietaryEnergyConsumed, randomBetween(1600, 2800), .kilocalorie()),
                (.dietaryProtein, randomBetween(60, 180), .gram()),
                (.dietaryCarbohydrates, randomBetween(150, 350), .gram()),
                (.dietaryFatTotal, randomBetween(40, 100), .gram()),
                (.dietaryFiber, randomBetween(10, 40), .gram()),
                (.dietarySodium, randomBetween(1000, 3000), .gramUnit(with: .milli)),
                (.dietarySugar, randomBetween(20, 80), .gram()),
                (.dietaryCholesterol, randomBetween(100, 300), .gramUnit(with: .milli)),
                (.dietaryVitaminC, randomBetween(50, 200), .gramUnit(with: .milli)),
                (.dietaryVitaminD, randomBetween(200, 1000), .gramUnit(with: .micro)),
                (.dietaryCalcium, randomBetween(500, 1300), .gramUnit(with: .milli)),
                (.dietaryIron, randomBetween(8, 18), .gramUnit(with: .milli)),
                (.dietaryMagnesium, randomBetween(200, 420), .gramUnit(with: .milli)),
                (.dietaryZinc, randomBetween(5, 15), .gramUnit(with: .milli)),
                (.dietaryPotassium, randomBetween(2000, 4700), .gramUnit(with: .milli)),
                (.dietaryVitaminB12, randomBetween(1, 6), .gramUnit(with: .micro)),
                (.dietaryFolate, randomBetween(200, 600), .gramUnit(with: .micro)),
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
                let q = HKQuantity(unit: .literUnit(with: .milli), doubleValue: randomBetween(150, 400))
                samples.append(quantitySample(type: .dietaryWater, quantity: q, start: ts))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Workouts

    func seedWorkouts() async throws -> Int {
        let calendar = Calendar.current
        let workoutTypes: [HKWorkoutActivityType] = [
            .running, .cycling, .walking, .swimming, .functionalStrengthTraining,
            .yoga, .highIntensityIntervalTraining, .elliptical, .rowing
        ]

        var count = 0

        for dayOffset in 0..<days {
            guard dayOffset % 2 == 0 || Bool.random() else { continue }
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let workoutType = workoutTypes.randomElement()!
            let hour = Int.random(in: 6...19)
            let start = Calendar.current.date(bySettingHour: hour, minute: Int.random(in: 0...30), second: 0, of: day)!
            let duration = TimeInterval(Int.random(in: 20...90) * 60)
            let end = start.addingTimeInterval(duration)
            let calories = randomBetween(150, 700)

            let config = HKWorkoutConfiguration()
            config.activityType = workoutType
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)

            try await builder.beginCollection(at: start)

            let aeq = HKQuantity(unit: .kilocalorie(), doubleValue: calories)
            let aeSample = HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: aeq, start: start, end: end)
            try await builder.addSamples([aeSample])

            if workoutType == .running || workoutType == .cycling || workoutType == .walking {
                let distValue = workoutType == .cycling ? randomBetween(5000, 40000) : randomBetween(2000, 12000)
                let dq = HKQuantity(unit: .meter(), doubleValue: distValue)
                let dSample = HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning), quantity: dq, start: start, end: end)
                try await builder.addSamples([dSample])
            }

            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
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
                let hour = Int.random(in: 0...23)
                let ts = dayStart.addingTimeInterval(Double(hour * 3600 + Int.random(in: 0...3599)))
                let q = HKQuantity(unit: .percent(), doubleValue: randomBetween(0.94, 0.99))
                samples.append(quantitySample(type: .oxygenSaturation, quantity: q, start: ts))
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
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                samples.append(quantitySample(type: .bloodGlucose, quantity: HKQuantity(unit: unit, doubleValue: value), start: ts))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Blood Pressure

    func seedBloodPressure() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let mmHg = HKUnit.millimeterOfMercury()

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!

            for hour in [7, 13, 19] {
                let ts = Calendar.current.date(bySettingHour: hour, minute: Int.random(in: 0...30), second: 0, of: day)!
                samples.append(quantitySample(type: .bloodPressureSystolic, quantity: HKQuantity(unit: mmHg, doubleValue: randomBetween(110, 135)), start: ts))
                samples.append(quantitySample(type: .bloodPressureDiastolic, quantity: HKQuantity(unit: mmHg, doubleValue: randomBetween(65, 85)), start: ts))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Body Temperature

    func seedBodyTemperature() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
            let q = HKQuantity(unit: .degreeCelsius(), doubleValue: randomBetween(36.2, 37.2))
            samples.append(quantitySample(type: .bodyTemperature, quantity: q, start: ts))
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
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                let q = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: randomBetween(12, 20))
                samples.append(quantitySample(type: .respiratoryRate, quantity: q, start: ts))
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
            let ts = Calendar.current.date(bySettingHour: 7, minute: Int.random(in: 0...30), second: 0, of: day)!
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
                let q = HKQuantity(unit: dbUnit, doubleValue: randomBetween(45, 80))
                samples.append(quantitySample(type: .environmentalAudioExposure, quantity: q, start: ts, end: ts.addingTimeInterval(7200)))
            }

            if Bool.random() {
                let ts = dayStart.addingTimeInterval(Double(Int.random(in: 10...20) * 3600))
                let q = HKQuantity(unit: dbUnit, doubleValue: randomBetween(55, 85))
                samples.append(quantitySample(type: .headphoneAudioExposure, quantity: q, start: ts, end: ts.addingTimeInterval(3600)))
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
            let ts = Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: day)!

            let bbt = randomBetween(36.0, 37.0)
            samples.append(HKQuantitySample(type: HKQuantityType(.basalBodyTemperature), quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: bbt), start: ts, end: ts))

            if dayOffset % 3 == 0 {
                let values: [HKCategoryValueCervicalMucusQuality] = [.dry, .sticky, .creamy, .watery, .eggWhite]
                samples.append(HKCategorySample(type: HKCategoryType(.cervicalMucusQuality), value: values.randomElement()!.rawValue, start: ts, end: ts.addingTimeInterval(86400)))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Vitamins & Supplements

    func seedVitamins() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        let vitamins: [(HKQuantityTypeIdentifier, Double, HKUnit)] = [
            (.dietaryVitaminC, 1000, .gramUnit(with: .milli)),
            (.dietaryVitaminD, 2000, .gramUnit(with: .micro)),
            (.dietaryVitaminB12, 1000, .gramUnit(with: .micro)),
            (.dietaryMagnesium, 400, .gramUnit(with: .milli)),
            (.dietaryZinc, 15, .gramUnit(with: .milli)),
            (.dietaryFolate, 400, .gramUnit(with: .micro)),
        ]

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let ts = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: day)!

            for (id, amount, unit) in vitamins {
                let q = HKQuantity(unit: unit, doubleValue: amount * Double.random(in: 0.8...1.2))
                samples.append(quantitySample(type: id, quantity: q, start: ts))
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
            let ts = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!

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

            // Walking speed (m/s) — multiple readings during active hours
            for hour in [9, 11, 14, 17] {
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                let end = ts.addingTimeInterval(600)
                samples.append(quantitySample(type: .walkingSpeed, quantity: HKQuantity(unit: HKUnit(from: "m/s"), doubleValue: randomBetween(1.0, 1.8)), start: ts, end: end))
                samples.append(quantitySample(type: .walkingStepLength, quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: randomBetween(60, 80)), start: ts, end: end))
                samples.append(quantitySample(type: .walkingDoubleSupportPercentage, quantity: HKQuantity(unit: .percent(), doubleValue: randomBetween(0.20, 0.35)), start: ts, end: end))
            }

            // Stair speeds a few times a week
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

    // MARK: - Wrist Temperature
    // appleSleepingWristTemperature is written exclusively by Apple Watch firmware.
    // Third-party apps cannot write to this type — returns 0 gracefully.
    func seedWristTemperature() async throws -> Int { return 0 }

    // MARK: - Daylight Exposure

    func seedDaylight() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let dayStart = calendar.startOfDay(for: day)

            // Total daily daylight in minutes, aggregated in blocks
            let totalMinutes = Int(randomBetween(20, 120))
            // Split into 1-3 outdoor blocks during the day
            let blocks = Int.random(in: 1...3)
            var remaining = totalMinutes
            let outdoorHours = [9, 12, 16, 18].shuffled().prefix(blocks)

            for hour in outdoorHours {
                guard remaining > 0 else { break }
                let blockMin = min(Int.random(in: 10...45), remaining)
                let ts = dayStart.addingTimeInterval(Double(hour * 3600))
                let end = ts.addingTimeInterval(Double(blockMin) * 60)
                let q = HKQuantity(unit: .minute(), doubleValue: Double(blockMin))
                samples.append(quantitySample(type: .timeInDaylight, quantity: q, start: ts, end: end))
                remaining -= blockMin
            }
        }

        try await save(samples)
        return samples.count
    }
}
