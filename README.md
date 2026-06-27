# HealthSeeder

An iOS app that seeds realistic, richly varied Apple Health data into the Xcode Simulator — covering today, or the last 30, 90, 180, or 365 days — so you can take meaningful App Store screenshots without needing a real device with months of history.

---

## Why

If your app reads from Apple Health, your Simulator screenshots look empty by default. HealthSeeder fixes that by writing thousands of realistic samples across all major health categories, giving every chart, ring, and metric something meaningful to display.

---

## What gets seeded

### Activity & Steps
Steps with a realistic hourly distribution, walking distance, active calories, basal calories, flights climbed.

### Heart Rate
Hourly readings with day/night variation (lower during sleep), resting heart rate, heart rate variability (HRV), VO2 Max (weekly).

### Sleep
Deep, REM, Core, and Awake stages in sequential non-overlapping blocks following a realistic 90-minute cycle pattern.

### Body Measurements
Weight with daily drift, BMI, body fat %, lean mass, waist circumference, height.

### Nutrition
A single consolidated daily entry covering all 39 HealthKit nutritional types at DRI-aligned values:

**Macros:** energy, protein, carbohydrates, total fat, saturated fat, monounsaturated fat, polyunsaturated fat, fibre, sugar, cholesterol.

**Fluids & electrolytes:** water, sodium, potassium, chloride.

**Fat-soluble vitamins:** A, D, E, K.

**Water-soluble vitamins:** C, B6, B12, thiamin (B1), riboflavin (B2), niacin (B3), pantothenic acid, biotin (B7), folate.

**Minerals:** calcium, iron, magnesium, zinc, phosphorus, copper, manganese, selenium, iodine, chromium, molybdenum.

**Other:** caffeine.

### Hydration
Water intake logged separately in 8 daily windows (complements the nutrition entry).

### Workouts
Running, cycling, walking, swimming, strength training, yoga, HIIT, elliptical, rowing — on alternating days with realistic duration and calorie data.

### Blood Oxygen
4–8 SpO2 readings per day.

### Blood Glucose
Fasting and post-meal readings (6 per day).

### Blood Pressure
Systolic and diastolic saved as `HKCorrelation`, 3 times per day.

### Body Temperature
One morning reading per day.

### Respiration
Respiratory rate, 5 readings per day.

### Mindfulness
Meditation sessions on alternating days.

### Menstrual Cycle
Flow data with cycle-start metadata across realistic 26–32 day cycles.

### Hearing
Environmental audio exposure (every 2 hours) and headphone exposure (on random days).

### Reproductive Health
Basal body temperature and cervical mucus quality every 3 days.

### Lab Results
Monthly fasting glucose and peripheral perfusion index.

### Walking Metrics
Walking speed, step length, double support percentage (4 readings per day), stair ascent and descent speed (every 3 days).

### Daylight Exposure
Daily outdoor time split across 1–3 blocks.

---

## System-only types (not injectable)

The following types are generated exclusively by Apple Watch firmware. HealthSeeder lists them in the UI but skips them gracefully — no error is thrown:

- `appleExerciseTime`
- `appleStandHour`
- `walkingHeartRateAverage`
- `walkingAsymmetryPercentage`
- `appleSleepingWristTemperature`

---

## Requirements

- Xcode 15 or later
- iOS 16 deployment target or later
- Swift 5.9 or later
- Xcode Simulator (iPhone or iPad)

---

## Setup

### 1. Create a new Xcode project

Open Xcode and go to **File > New > Project > App**. Set the product name to `HealthSeeder` and choose any bundle identifier in the format `com.yourname.HealthSeeder`.

### 2. Add the source files

Replace the files Xcode generates with the files from this repository:

- `HealthSeederApp.swift`
- `HealthSeeder.swift`
- `ContentView.swift`

### 3. Enable HealthKit

Select the `HealthSeeder` target, go to **Signing & Capabilities**, click **+ Capability**, and add **HealthKit**.

### 4. Add usage descriptions

Select the target, go to the **Info** tab, and add two keys under **Custom iOS Target Properties**:

| Key | Value |
|---|---|
| Privacy - Health Share Usage Description | HealthSeeder reads Apple Health data. |
| Privacy - Health Update Usage Description | HealthSeeder writes sample data for testing and screenshots. |

### 5. Run in the Simulator

Select any iPhone simulator running iOS 16 or later and press **Cmd+R**. When prompted, grant all HealthKit permissions. The app requests authorisation in small batches with a short pause between each — you will see several permission dialogs in sequence. Accept all of them and wait for each to dismiss before the next appears.

### 6. Seed the data

Choose your desired period (Today only, 30, 90, 180, or 365 days) and tap **Seed Health Data**. Seeding 365 days typically takes 1–3 minutes. A progress bar tracks each category as it completes.

### 7. Verify

Open the **Health** app on the same Simulator to confirm data is present before taking your screenshots.

---

## Deleting seeded data

Tap **Delete All Seeded Data** in the app. This uses `HKHealthStore.deleteObjects(of:predicate:)` to remove only the samples written by HealthSeeder across all types.

> **Note:** Some data injected by the Simulator itself (such as default weight or height entries) cannot be removed by any third-party app. To wipe Apple Health completely, use **Device > Erase All Content and Settings** in the Simulator menu, or run `xcrun simctl erase booted` in Terminal. The app includes a **Full Health Reset** button with step-by-step instructions for both methods.

---

## Checking permissions

Tap **Check Permissions** to see a breakdown of which HealthKit types are authorised, denied, or not yet determined. If any types are missing, a **Request Missing Permissions** button appears inside the sheet.

---

## Limitations

- Simulator only. HealthKit on a real device requires a physical Apple Watch for several metric types and behaves differently for authorisation.
- Data is randomised on each run, so exact values will differ between sessions.
- Running the seeder multiple times without deleting first will create duplicate samples.
- `dietaryCholine` has no standalone `HKQuantityTypeIdentifier` in HealthKit and is therefore not included — Apple only supports it inside `HKCorrelation` food entries.

---

## Contributing

Pull requests are welcome. If you discover additional HealthKit types that are writable by third-party apps and useful for screenshots, please open an issue or submit a PR adding them to the relevant seed function in `HealthSeeder.swift`.

---

## Licence

MIT
