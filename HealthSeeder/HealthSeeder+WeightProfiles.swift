//
//  HealthSeeder+WeightProfiles.swift
//  HealthSeeder
//
//  Deterministic body-mass generator for testing the Weight Patterns feature.
//
//  It replaces the old random-walk seedBodyMeasurements (a directionless
//  ±0.3 kg-every-3-days walk that almost never produced a sustained window that
//  cleared the detector's duration / fraction / persistence tests, and left the
//  feature stuck on "early signal").
//
//  Instead of noise, this builds an explicit day-by-day weight series out of
//  named segments (flat plateau, sustained drop ramp, sustained gain ramp),
//  calibrated so each profile lands EXACTLY on one analysis state:
//
//    .collecting  short flat history, below the history floor, zero windows.
//    .emerging    one clean drop ramp, one drop window, below the established
//                 window bar.
//    .established multiple drop and gain ramps separated by neutral plateaus,
//                 clearing the established window bar on both contexts, so the
//                 rich screen shows both sections side by side.
//
//  ---------------------------------------------------------------------------
//  WHY THE NUMBERS ARE WHAT THEY ARE (read against WeightPatternsConfig and
//  WeightWindowDetector before changing anything):
//
//    - Weigh-ins are DAILY, not every 3 days. Two reasons, both hard gates:
//        * establishedWeighInsPerWeek == 3. Every-3-days is 2.33/week and can
//          NEVER reach established, whatever the shape. Daily is 7/week.
//        * movingAverageMinPointsInWindow == 3 over a 7-day window. Every-3-days
//          leaves ~2-3 real points per window, so many days get no smoothed
//          value and never enter segmentation. Daily gives 7 points per window,
//          well clear of 3, so every interior day is smoothed.
//
//    - Ramps are 21 real days, not 14. The detector measures a block's span
//      between its FIRST and LAST SMOOTHED day, and the 7-day moving average
//      shortens the visible monotonic stretch at both ends. 21 real days leaves
//      a smoothed monotonic core comfortably above sustainedDropMinDays (14).
//
//    - Ramp net move is ~4%, well above sustainedDropMinFraction (1%), so the
//      smoothing never erodes the net move below the bar.
//
//    - Ramps are strictly monotonic (each day strictly below/above the last),
//      so the directional-persistence test (sustainedDropMinDownStepFraction
//      0.70) sees ~100% agreeing steps.
//
//    - Neutral plateaus carry a deliberate ZIG-ZAG (alternating up/down steps
//      larger than any residual ramp drift), NOT flat micro-noise. A too-flat
//      plateau reads as "non-ascending" and gets absorbed into an adjacent drop
//      block, merging two windows into one giant window and breaking the count.
//      The zig-zag makes the plateau fail BOTH the drop persistence test and
//      the gain persistence test, so those days fall out as neutral and the
//      windows stay distinct and countable.
//  ---------------------------------------------------------------------------
//
//  Every value is written with the HVPLoggedAt metadata key so it is
//  indistinguishable in provenance from real HVP-authored samples, and is
//  removed by the existing "Delete All Seeded Data" path (which deletes by type,
//  not by metadata, so nothing special is needed here).
//

import Foundation
import HealthKit

// MARK: - Profile selector

/// Which analysis state the generated weight series should drive the feature to.
enum WeightProfile: String, CaseIterable, Identifiable {
    case collecting
    case emerging
    case established

    var id: String { rawValue }

    /// Short label for the seeder UI picker.
    var label: String {
        switch self {
        case .collecting:  return "Collecting"
        case .emerging:    return "Emerging"
        case .established: return "Established"
        }
    }

    /// One-line description of what the profile produces, for the seeder UI.
    var detail: String {
        switch self {
        case .collecting:
            return "Short flat history. Below the history floor, zero windows."
        case .emerging:
            return "One drop ramp. One window, below the established bar."
        case .established:
            return "Multiple drop and gain ramps. Both contexts established."
        }
    }

    /// How many days of history this profile writes. The collecting profile is
    /// deliberately short (below minimumHistoryWeeks * 7) so it fails the
    /// history floor cleanly; the other two span a full year.
    var historyDays: Int {
        switch self {
        case .collecting:  return 30
        case .emerging:    return 365
        case .established: return 365
        }
    }
}

// MARK: - Segment model

/// One contiguous stretch of the weight series, oldest-to-newest.
private enum WeightSegment {
    /// Flat-ish plateau with a zig-zag that breaks directional persistence so
    /// these days land as neutral. `days` long, centered on `level` kg.
    case neutral(days: Int, level: Double)
    /// Strictly decreasing ramp: `days` long, losing `dropFraction` of the
    /// starting weight linearly.
    case drop(days: Int, dropFraction: Double)
    /// Strictly increasing ramp: `days` long, gaining `gainFraction` of the
    /// starting weight linearly.
    case gain(days: Int, gainFraction: Double)
}

// MARK: - Generator

extension HealthSeeder {

    // The selected profile lives as a @Published property on HealthSeeder
    // itself (see HealthSeeder.swift), so the ContentView picker binds to it
    // directly and the description animates reactively.

    /// Replacement for the old random-walk body-measurements seeder. Builds a
    /// deterministic daily weight series for the selected profile, plus the
    /// companion body metrics (BMI, body fat, lean mass, waist, height) so the
    /// Your Body screen stays populated.
    ///
    /// NOTE: this ignores `self.days` for the weight SERIES itself and uses the
    /// profile's own historyDays, because each profile's state depends on an
    /// exact history length. The companion metrics still span the same window.
    func seedBodyMeasurementsForProfile() async throws -> Int {
        var samples: [HKSample] = []
        let calendar = Calendar.current
        let profile  = selectedWeightProfile

        let height  = randomBetween(170, 182)
        let bodyFat = randomBetween(15, 24)

        // Height: one sample at the oldest point.
        let oldest = calendar.date(byAdding: .day, value: -profile.historyDays, to: Date())!
        samples.append(quantitySample(
            type: .height,
            quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: height),
            start: oldest
        ))

        // Build the oldest-to-newest daily weight series for this profile.
        let series = weightSeries(for: profile, startWeight: 82.0)

        // Series index 0 is the OLDEST day (historyDays ago); the last index is
        // yesterday. We stop at yesterday so today is never half-populated.
        let dayCount = series.count
        for (idx, kg) in series.enumerated() {
            // Oldest day first: offset counts back from today.
            let dayOffset = dayCount - idx        // 1 == yesterday
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let ts = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: day)!

            let bmi  = kg / pow(height / 100, 2)
            let lean = kg * (1 - bodyFat / 100)

            samples.append(weightSample(kg: kg, start: ts))
            samples.append(quantitySample(type: .bodyMassIndex, quantity: HKQuantity(unit: .count(), doubleValue: bmi), start: ts))
            samples.append(quantitySample(type: .bodyFatPercentage, quantity: HKQuantity(unit: .percent(), doubleValue: bodyFat / 100), start: ts))
            samples.append(quantitySample(type: .leanBodyMass, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: lean), start: ts))
            samples.append(quantitySample(type: .waistCircumference, quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: 80 + (kg - 82) * 0.5), start: ts))
        }

        try await save(samples)
        return samples.count
    }

    // MARK: - Series construction

    /// Assembles the ordered segment list for a profile and flattens it into a
    /// day-by-day kilogram array, oldest first.
    private func weightSeries(for profile: WeightProfile, startWeight: Double) -> [Double] {
        let segments: [WeightSegment]

        switch profile {
        case .collecting:
            // 30 flat days, no ramp. Below minimumHistoryWeeks (8 * 7 == 56),
            // and zero windows of either kind. Falls to collecting on the
            // history floor.
            segments = [
                .neutral(days: 30, level: startWeight)
            ]

        case .emerging:
            // A full year, but exactly ONE drop ramp. History and frequency are
            // well past the established bar, so the ONLY thing holding the
            // global state at emerging is the window count: one drop window
            // (>= minimumDropWindows 1, < establishedDropWindows 2), zero gain
            // windows. This isolates the window-count variable cleanly.
            //
            // Long neutral padding on both sides so weeksOfHistory and
            // weighInsPerWeek sit comfortably in the established range while the
            // window count alone keeps it emerging.
            segments = [
                .neutral(days: 160, level: startWeight),
                .drop(days: 21, dropFraction: 0.04),
                .neutral(days: 184, level: startWeight * 0.96)
            ]

        case .established:
            // A full year with TWO drop ramps and TWO gain ramps, each separated
            // by a neutral plateau. Both contexts reach establishedDropWindows
            // (2), history and frequency are maxed, so the global state is
            // established and the rich screen shows both a drop section and a
            // gain section, each at the confirmed tier.
            //
            // Weights are chained so each ramp starts where the previous segment
            // left off (see flatten). Fractions kept ~4% so every ramp clears
            // sustainedDropMinFraction (1%) with margin after smoothing.
            segments = [
                .neutral(days: 35, level: startWeight),          // baseline
                .drop(days: 21, dropFraction: 0.04),             // drop window 1
                .neutral(days: 35, level: 0),                    // level filled at flatten
                .gain(days: 21, gainFraction: 0.04),             // gain window 1
                .neutral(days: 35, level: 0),
                .drop(days: 21, dropFraction: 0.04),             // drop window 2
                .neutral(days: 35, level: 0),
                .gain(days: 21, gainFraction: 0.04),             // gain window 2
                .neutral(days: 42, level: 0)                     // tail
            ]
        }

        return flatten(segments, startWeight: startWeight)
    }

    /// Flattens segments into a daily kg array, oldest first. Each segment
    /// begins at the weight the previous segment ended on, so ramps chain
    /// naturally. Neutral segments with `level == 0` inherit the running weight
    /// (used by the established chain, where intermediate levels are not known
    /// up front).
    private func flatten(_ segments: [WeightSegment], startWeight: Double) -> [Double] {
        var out: [Double] = []
        var running = startWeight

        for segment in segments {
            switch segment {
            case let .neutral(days, level):
                let base = level == 0 ? running : level
                // Zig-zag around the base: alternating +/- steps large enough to
                // break the 70% directional-persistence test in BOTH directions,
                // so these days are neither a drop nor a gain and fall out as
                // neutral. Amplitude ~0.5 kg, larger than any ramp per-day drift.
                for d in 0..<days {
                    let sign = (d % 2 == 0) ? 1.0 : -1.0
                    out.append(base + sign * 0.5)
                }
                running = base

            case let .drop(days, dropFraction):
                let target = running * (1 - dropFraction)
                let step   = (running - target) / Double(days)
                // Strictly decreasing, one step per day.
                for d in 1...days {
                    out.append(running - step * Double(d))
                }
                running = target

            case let .gain(days, gainFraction):
                let target = running * (1 + gainFraction)
                let step   = (target - running) / Double(days)
                // Strictly increasing, one step per day.
                for d in 1...days {
                    out.append(running + step * Double(d))
                }
                running = target
            }
        }
        return out
    }

    // MARK: - Sample builder with HVP provenance

    /// Builds a body-mass sample carrying the HVPLoggedAt metadata key, matching
    /// how real HVP-authored weight is stamped, so the feature's source handling
    /// treats seeded weight the same as production weight.
    private func weightSample(kg: Double, start: Date) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.bodyMass),
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
            start: start,
            end: start,
            metadata: ["HVPLoggedAt": start]
        )
    }
}
