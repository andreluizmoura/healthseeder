# HealthSeeder

An iOS app that seeds realistic, richly varied Apple Health data into the Xcode Simulator — covering the last 30, 90, 180, or 365 days — so you can take meaningful App Store screenshots without needing a real device with months of history.

---

## Why

If your app reads from Apple Health, your simulator screenshots look empty by default. HealthSeeder fixes that by writing thousands of realistic samples across all major health categories, giving every chart, ring, and metric something meaningful to display.

---

## What gets seeded

| Category | Data points |
|---|---|
| Activity & Steps | Steps (hourly distribution), distance, active calories, basal calories, flights climbed |
| Heart Rate | Hourly readings with day/night variation, resting HR, HRV, VO2 Max |
| Sleep | Deep, REM, Core, and Awake stages in realistic 90-minute cycles |
| Body Measurements | Weight (daily drift), BMI, body fat %, lean mass, waist circumference, height |
| Nutrition | Calories, protein, carbs, fat, fibre, sugar, cholesterol, sodium, 8 vitamins and minerals |
| Hydration | Water intake in 8 daily windows |
| Workouts | Running, cycling, walking, swimming, strength, yoga, HIIT, elliptical, rowing |
| Blood Oxygen | 4–8 SpO2 readings per day |
| Blood Glucose | Fasting and post-meal readings (6 per day) |
| Blood Pressure | Systolic and diastolic, 3 times per day |
| Body Temperature | One morning reading per day |
| Respiration | Respiratory rate, 5 readings per day |
| Mindfulness | Meditation sessions on alternating days |
| Menstrual Cycle | Flow data with cycle-start metadata |
| Hearing | Environmental noise and headphone exposure |
| Reproductive Health | Basal body temperature and cervical mucus quality |
| Vitamins & Supplements | Vitamin C, D, B12, magnesium, zinc, folate |
| Lab Results | Monthly fasting glucose and peripheral perfusion index |
| Walking Metrics | Walking speed, step length, double support %, stair ascent/descent speed |
| Daylight Exposure | Daily outdoor time in 1–3 blocks |

> **Note:** Some types — including `appleExerciseTime`, `appleStandHour`, `walkingHeartRateAverage`, `walkingAsymmetryPercentage`, and `appleSleepingWristTemperature` — are written exclusively by Apple Watch firmware and cannot be injected by third-party apps. These are listed in the UI but skipped gracefully.

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

Select any iPhone simulator running iOS 16 or later and press **Cmd+R**. When prompted, grant all HealthKit permissions. Because the type list is large, the app requests authorisation in batches — you may see multiple permission dialogs in sequence. Accept all of them.

### 6. Seed the data

Choose your desired period (30, 90, 180, or 365 days) and tap **Seed Health Data**. Seeding 365 days typically takes 1–3 minutes. A progress bar tracks each category as it completes.

### 7. Verify

Open the **Health** app on the same simulator to confirm data is present before taking your screenshots.

---

## Resetting

To wipe all seeded data and start fresh, go to the Simulator menu and choose **Device > Erase All Content and Settings**, then re-run HealthSeeder.

Running the seeder multiple times without resetting will create duplicate samples.

---

## Limitations

- Simulator only. HealthKit on a real device requires a physical Apple Watch for several metric types and behaves differently for authorisation.
- Data is randomised on each run, so values will differ between sessions.
- Some health types are gated by Apple and cannot be written by third-party apps regardless of authorisation. These are noted in the table above.

---

## Contributing

Pull requests are welcome. If you discover additional HealthKit types that are writable by third-party apps and useful for screenshots, please open an issue or submit a PR adding them to the relevant seed function.

---

## Licence

MIT
