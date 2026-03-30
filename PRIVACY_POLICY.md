# Privacy Policy — LoxBridge

**App name:** LoxBridge  
**Developer:** LoxBridge (independent developer)  
**Contact:** loxbridge.employee017@slmail.me  
**Country:** Sweden  
**Effective date:** 2026-03-23 
**Latest revision:** March 2026  

---

## 1. Introduction

LoxBridge ("the app", "we", "us") is an iOS application that reads GPS workout routes from Apple Health and uploads them to Livelox, a route-analysis service for orienteering.

This Privacy Policy explains what data the app accesses, how it is used, and what rights you have.

By using LoxBridge, you acknowledge that you have read and understood this Privacy Policy.

---

## 2. Data We Access

### 2.1 Health and Workout Data (HealthKit)

LoxBridge requests read-only access to the following HealthKit data types:

| Data type | Purpose |
|---|---|
| Workout sessions | Detect new outdoor workouts to process |
| Workout routes (GPS tracks) | Extract the GPS path to generate a GPX file |
| Workout metadata (duration, distance, device name) | Include stats in the route history display |

**LoxBridge does not write any data back to Apple Health.**  
HealthKit data is accessed strictly for the purposes described in this policy and only with your explicit permission.

---

### 2.2 Location Data (Derived from Workouts)

GPS coordinates are read from workout routes already recorded and stored in the Apple Health app by your Apple Watch or iPhone.

LoxBridge does **not** request access to your current live location.

After processing a workout, the app performs a reverse-geocoding lookup (using Apple's `CLGeocoder` service) to derive a human-readable place name (e.g. "Skatås, Göteborg") for display.

No servers controlled by LoxBridge receive this data. Apple may process this data as part of its geocoding service.

---

### 2.3 Device Information

LoxBridge reads the name and hardware model identifier of the device that recorded the workout (e.g. "Erik's Apple Watch (Watch6,1)") from HealthKit metadata.

This information is:
- displayed in the app
- optionally included in the GPX file sent to Livelox

---

### 2.4 Data We Do NOT Collect

- We do **not directly collect** your name, email address, or account information  
- We do **not** collect advertising identifiers (IDFA) or perform device fingerprinting  
- We do **not** use analytics SDKs (e.g. Firebase, Amplitude, Mixpanel)  
- We do **not** use third-party crash reporting services  
- We do **not** track your location in real time  
- We do **not** run background processes that continuously collect data  

---

## 3. How Your Data Is Used

| Purpose | Data involved |
|---|---|
| Generate a GPX file | GPS track, timestamps |
| Display route history | Date, distance, duration, activity type, location name, device name |
| Upload routes to Livelox (user-initiated) | GPX file |
| Notifications | No personal data |

All processing happens **on your device**.

LoxBridge does not operate its own servers.

We do not use your data for any purpose other than those listed above.

---

## 4. Data Shared with Third Parties

### 4.1 Livelox

When you choose to upload a route, LoxBridge sends a **GPX file** to Livelox via HTTPS.

The GPX file may contain:
- GPS coordinates (latitude, longitude, altitude)
- timestamps
- optional metadata (activity type, duration, distance, device name)

Livelox is operated by **Livelox AB (Sweden)**.

By uploading a route:
- you enter into a direct relationship with Livelox  
- your data becomes subject to Livelox’s own policies  

LoxBridge has no control over how Livelox processes your data after upload.

OAuth tokens are stored securely in the iOS Keychain and are only sent to Livelox.

---

### 4.2 Apple (Geocoding)

Apple’s geocoding service may process GPS coordinates to provide place names.

This is governed by Apple’s own privacy policy.

---

### 4.3 No Other Third Parties

No data is shared with:
- advertisers  
- data brokers  
- analytics providers  

---

## 5. Data Storage and Security

| Location | Data stored | Access |
|---|---|---|
| Device (App Support) | GPX files | Private |
| UserDefaults | Route metadata, settings | Private |
| Keychain | OAuth tokens | Encrypted |
| Livelox servers | Uploaded routes | External |

All communication uses HTTPS (TLS).

Deleting the app will remove locally stored data from the device, although iOS backups may retain data according to Apple’s policies.

---

## 6. Data Retention

| Data | Retention |
|---|---|
| GPX files | Until deleted or app uninstalled |
| Route metadata | Until deleted |
| OAuth tokens | Until disconnected or app removed |
| Livelox data | Controlled by Livelox |

---

## 7. Your Rights and Controls

You can:

- Revoke HealthKit access via iOS Settings  
- Delete routes inside the app  
- Disconnect Livelox  
- Perform a full reset of app data  

Some rights must be exercised directly with third parties such as Livelox.

---

## 8. GDPR — EU/EEA Users

You have the right to:

- Access your data  
- Request deletion  
- Restrict processing  
- Data portability  
- Object to processing  
- Withdraw consent  

**Legal basis:** Explicit consent

Most data processing occurs locally on your device.

To exercise your rights, contact:  
loxbridge.employee017@slmail.me

---

## 9. California Privacy Rights (CCPA / CPRA)

You have the right to:

- Know what data is collected  
- Request deletion  
- Opt out of sale of data  

LoxBridge does **not sell or share personal data** as defined under CCPA/CPRA.

---

## 10. Children's Privacy

LoxBridge can be used by people of all ages. However, the app is not specifically designed for children under the age of 13 (or 16 in the EU).

The app does not knowingly collect personal information directly from users, and does not include account creation, social features, or advertising.

Health and workout data accessed by the app comes from Apple Health and is only processed locally on the device, or shared with Livelox when initiated by the user.

If you believe that a child has used the app in a way that raises privacy concerns, please contact us and we will take appropriate steps.

---

## 11. HealthKit Compliance

- Data is used only for core functionality  
- Never used for advertising or profiling  
- Never sold  
- Only shared with Livelox when user initiates  

---

## 12. Changes to This Policy

We may update this policy from time to time.

The revision date will be updated accordingly.

Where required by law, we will obtain your consent before applying significant changes.

---

## 13. Contact

For questions or requests:

**Developer:** LoxBridge (independent developer)  
**Email:** loxbridge.employee017@slmail.me  
**Country:** Sweden  

---

*This policy is designed to comply with Apple App Store requirements, GDPR, and CCPA.*
