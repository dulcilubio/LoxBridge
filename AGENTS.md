# AGENTS.md

## Project Overview
LoxBrige is a minimal iOS utility app that automatically detects completed workouts recorded by an Apple Watch via HealthKit.

When a workout finishes:
1. The app extracts the GPS route (HKWorkoutRoute)
2. Converts the route to GPX
3. Stores the GPX locally
4. Shows a notification asking if the user wants to upload the route to Livelox
5. If accepted, the GPX is uploaded to the Livelox API using OAuth user delegation.

The app has minimal UI and runs mostly in the background.

## Tech Stack

Language: Swift  
Frameworks:
- HealthKit
- CoreLocation
- UserNotifications
- URLSession

## Architecture

HealthKitManager  
WorkoutObserver  
WorkoutProcessor  
RouteExtractor  
GPXBuilder  
StorageManager  
NotificationManager  
OAuthManager  
LiveloxUploader

## Key Constraints

- No backend server
- OAuth user delegation with Livelox API
- All GPS routes stored as GPX
- Upload triggered via notification action
- Background HealthKit delivery enabled

## Project Structure

Sources/
- HealthKitManager.swift
- WorkoutObserver.swift
- WorkoutProcessor.swift
- RouteExtractor.swift
- GPXBuilder.swift
- StorageManager.swift
- NotificationManager.swift
- OAuthManager.swift
- LiveloxUploader.swift
