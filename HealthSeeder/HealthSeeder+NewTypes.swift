//
//  HealthSeeder+NewTypes.swift
//  HealthSeeder
//
//  Phase 2 data for HealthVitals Pro (types third party apps can write):
//
//      - Alcohol: about 40% of days, 1 to 4 drinks in the evening, more on
//        weekends. Other days have NO log, which exercises the rule that a
//        day without a log is absent, not zero.
//      - Physical Effort (METs): light samples through the day, a 20 minute
//        moderate walk, and 15 to 30 vigorous minutes on some days.
//      - Running form (runs), power and cadence (about 70% of rides), FTP
//        every 30 days, and a user effort rating on about 60% of workouts
//        (iOS 18). These are added from seedWorkouts.
//
//  Apple only types are NOT requested. Asking to share a type apps cannot
//  write raises an Objective C exception (NSInvalidArgumentException,
//  "Authorization to share the following types is disallowed") that Swift
//  cannot catch, so the app crashes. Confirmed with
//  appleWalkingSteadinessEvent and walkingAsymmetryPercentage. The same applies to Apple's notifications
//  and Apple calculated values: Walking Steadiness, Low Cardio Fitness,
//  sound notifications, Breathing Disturbances, sleep apnea, AFib History,
//  hypertension and the estimated workout effort. Those screens can only be
//  tested with real Apple Watch data.
//
//  Physical Effort is requested on its own, last, so if it ever turns out
//  to be disallowed the crash points straight at it.
//

import Foundation
import HealthKit

extension HealthSeeder {

    // MARK: - Types

    /// Phase 2 types third party apps can write (Physical Effort apart).
    var newWritableTypes: [HKSampleType] {
        var ids: [HKQuantityTypeIdentifier] = [
            .numberOfAlcoholicBeverages,
            .runningPower, .runningStrideLength,
            .runningVerticalOscillation, .runningGroundContactTime,
            .cyclingPower, .cyclingCadence, .cyclingFunctionalThresholdPower
        ]
        if #available(iOS 18.0, *) {
            ids.append(.workoutEffortScore)
        }
        return ids.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    /// Everything Delete All Seeded Data must also remove.
    var newTypesForDelete: [HKSampleType] {
        newWritableTypes + [HKQuantityType(.physicalEffort)]
    }

    func canWrite(_ type: HKObjectType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    // MARK: - Authorization

    /// Writable types in one request, then Physical Effort on its own.
    /// Never request a type apps cannot write: the exception it raises
    /// cannot be caught in Swift (see header).
    @MainActor
    func requestNewTypesAuth() async {
        do {
            try await store.requestAuthorization(toShare: Set(newWritableTypes), read: [])
        } catch {
            print("HealthSeeder: new types request failed: \(error)")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        do {
            try await store.requestAuthorization(toShare: [HKQuantityType(.physicalEffort)], read: [])
        } catch {
            print("HealthSeeder: physical effort request failed: \(error)")
        }
        // Let the sheet finish dismissing before the next request starts,
        // otherwise the next request times out (iOS 26 and later).
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    // MARK: - Day helpers

    /// Day `offset` days back from today, clamped to the selected period.
    private func dayBack(_ offset: Int) -> Date {
        let clamped = min(offset, max(days - 1, 0))
        return Calendar.current.date(byAdding: .day, value: -clamped, to: Date())!
    }

    private func at(_ hour: Int, _ minute: Int = 0, on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    // MARK: - Alcohol

    func seedAlcohol() async throws -> Int {
        let type = HKQuantityType(.numberOfAlcoholicBeverages)
        guard canWrite(type) else {
            print("HealthSeeder: alcohol not authorized")
            return 0
        }

        var samples: [HKSample] = []
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            let day     = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let weekday = calendar.component(.weekday, from: day)   // 1 Sunday, 6 Friday, 7 Saturday
            let isWeekend = weekday == 6 || weekday == 7
            let chance    = isWeekend ? 0.7 : 0.3
            guard Double.random(in: 0...1) < chance else { continue }   // no log that day

            let drinks = isWeekend ? Int.random(in: 1...4) : Int.random(in: 1...2)
            for i in 0..<drinks {
                let ts = at(19 + i, Int.random(in: 0...45), on: day)
                guard ts <= Date() else { continue }
                samples.append(quantitySample(
                    type: .numberOfAlcoholicBeverages,
                    quantity: HKQuantity(unit: .count(), doubleValue: 1),
                    start: ts
                ))
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Physical Effort

    func seedPhysicalEffort() async throws -> Int {
        let type = HKQuantityType(.physicalEffort)
        guard canWrite(type) else {
            print("HealthSeeder: physical effort not authorized")
            return 0
        }

        let mets = HKUnit.kilocalorie()
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        var samples: [HKSample] = []
        let calendar = Calendar.current

        func block(_ start: Date, minutes: Int, range: ClosedRange<Double>) {
            // One sample per 5 minutes across the block.
            var cursor = start
            let end = start.addingTimeInterval(Double(minutes) * 60)
            while cursor < end, cursor <= Date() {
                let next = min(cursor.addingTimeInterval(300), end)
                samples.append(HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: mets, doubleValue: Double.random(in: range)),
                    start: cursor, end: next
                ))
                cursor = next
            }
        }

        for dayOffset in 0..<days {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!

            // Light activity through the day.
            for hour in [9, 12, 15, 18] {
                block(at(hour, Int.random(in: 0...30), on: day), minutes: 10, range: 1.2...2.5)
            }
            // Moderate walk.
            block(at(Int.random(in: 7...8), Int.random(in: 0...30), on: day), minutes: 20, range: 3.2...4.5)
            // Vigorous minutes on about half of the days.
            if Bool.random() {
                block(at(Int.random(in: 17...19), Int.random(in: 0...30), on: day),
                      minutes: Int.random(in: 15...30), range: 6.0...9.0)
            }
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Workout sensors

    /// Running form, one sample per minute. Empty when not authorized.
    func runningFormSamples(start: Date, minutes: Int) -> [HKSample] {
        let types: [HKQuantityTypeIdentifier] = [
            .runningPower, .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime
        ]
        guard types.allSatisfy({ canWrite(HKQuantityType($0)) }) else { return [] }

        let power  = Double.random(in: 220...280)
        let stride = Double.random(in: 1.0...1.3)
        let osc    = Double.random(in: 7.0...10.0)
        let gct    = Double.random(in: 220...280)

        var samples: [HKSample] = []
        for minute in 0..<minutes {
            let s = start.addingTimeInterval(Double(minute) * 60)
            let e = s.addingTimeInterval(60)
            samples.append(HKQuantitySample(type: HKQuantityType(.runningPower),
                quantity: HKQuantity(unit: .watt(), doubleValue: power * Double.random(in: 0.9...1.1)), start: s, end: e))
            samples.append(HKQuantitySample(type: HKQuantityType(.runningStrideLength),
                quantity: HKQuantity(unit: .meter(), doubleValue: stride * Double.random(in: 0.95...1.05)), start: s, end: e))
            samples.append(HKQuantitySample(type: HKQuantityType(.runningVerticalOscillation),
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: osc * Double.random(in: 0.92...1.08)), start: s, end: e))
            samples.append(HKQuantitySample(type: HKQuantityType(.runningGroundContactTime),
                quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: gct * Double.random(in: 0.95...1.05)), start: s, end: e))
        }
        return samples
    }

    /// Cycling power and cadence, one sample per minute. Empty when not authorized.
    func cyclingSensorSamples(start: Date, minutes: Int) -> [HKSample] {
        guard canWrite(HKQuantityType(.cyclingPower)),
              canWrite(HKQuantityType(.cyclingCadence)) else { return [] }

        let power   = Double.random(in: 150...250)
        let cadence = Double.random(in: 75...95)
        let rpm     = HKUnit.count().unitDivided(by: .minute())

        var samples: [HKSample] = []
        for minute in 0..<minutes {
            let s = start.addingTimeInterval(Double(minute) * 60)
            let e = s.addingTimeInterval(60)
            samples.append(HKQuantitySample(type: HKQuantityType(.cyclingPower),
                quantity: HKQuantity(unit: .watt(), doubleValue: power * Double.random(in: 0.85...1.15)), start: s, end: e))
            samples.append(HKQuantitySample(type: HKQuantityType(.cyclingCadence),
                quantity: HKQuantity(unit: rpm, doubleValue: cadence * Double.random(in: 0.92...1.08)), start: s, end: e))
        }
        return samples
    }

    /// FTP every 30 days across the period.
    func seedFTP() async -> Int {
        let type = HKQuantityType(.cyclingFunctionalThresholdPower)
        guard canWrite(type) else { return 0 }

        var samples: [HKSample] = []
        var ftp = Double.random(in: 220...240)
        for offset in stride(from: max(days - 1, 0), through: 0, by: -30) {
            ftp += Double.random(in: -5...8)
            samples.append(HKQuantitySample(type: type,
                quantity: HKQuantity(unit: .watt(), doubleValue: ftp.rounded()),
                start: at(10, on: dayBack(offset)), end: at(10, on: dayBack(offset))))
        }
        do {
            try await save(samples)
            return samples.count
        } catch {
            print("HealthSeeder: FTP save failed: \(error)")
            return 0
        }
    }

    /// A user effort rating (1 to 10) related to about 60% of workouts.
    func relateEffortIfNeeded(to workout: HKWorkout) async {
        guard #available(iOS 18.0, *) else { return }
        let type = HKQuantityType(.workoutEffortScore)
        guard canWrite(type), Double.random(in: 0...1) < 0.6 else { return }

        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(Int.random(in: 3...9))),
            start: workout.startDate, end: workout.endDate
        )
        do {
            _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
        } catch {
            // Some systems need the sample saved before it can be related.
            do {
                try await store.save(sample)
                _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            } catch {
                print("HealthSeeder: effort relate failed: \(error)")
            }
        }
    }
}
