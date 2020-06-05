// LifecycleLogic.swift
// Copyright (C) 2020 Presidenza del Consiglio dei Ministri.
// Please refer to the AUTHORS file for more information.
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import BackgroundTasks
import Extensions
import Foundation
import Hydra
import ImmuniExposureNotification
import Katana
import Models
import PushNotification

extension Logic {
  enum Lifecycle {
    /// Launched when app is started
    struct OnStart: AppSideEffect, OnStartObserverDispatchable {
      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        let state = context.getState()

        // Prelaod animation assets. Check `PreloadAssets` action for better documentation.
        context.dispatch(Logic.Shared.PreloadAssets())

        // refresh statuses
        try context.awaitDispatch(Logic.Lifecycle.RefreshAuthorizationStatuses())

        // Update user language
        try context.awaitDispatch(SetUserLanguage(language: UserLanguage(from: context.dependencies.locale)))

        // Set the app name used in the application using the bundle's display name
        if let appName = context.dependencies.bundle.appDisplayName {
          try context.awaitDispatch(SetAppName(appName: appName))
        }

        // Set the app version used in the application using the bundle
        if let appVersion = context.dependencies.bundle.appVersion,
          let bundleVersion = context.dependencies.bundle.bundleVersion {
          try context.awaitDispatch(SetAppVersion(appVersion: "\(appVersion) (\(bundleVersion))"))
        }

        let isFirstLaunch = !state.toggles.isFirstLaunchSetupPerformed

        // Perform the setup related to the first launch of the application, if needed
        try context.awaitDispatch(PerformFirstLaunchSetupIfNeeded())

        // starts the exposure manager if possible
        try await(context.dependencies.exposureNotificationManager.startIfAuthorized())

        // clears `PositiveExposureResults` older than 14 days from the `ExposureDetectionState`
        try context.awaitDispatch(Logic.ExposureDetection.ClearOutdatedResults(now: context.dependencies.now()))

        // Removes notifications as the user has opened the app
        context.dispatch(Logic.CovidStatus.RemoveRiskReminderNotification())

        guard context.dependencies.application.isForeground else {
          // Background sessions are handled in `HandleExposureDetectionBackgroundTask`
          return
        }

        // refresh the analytics token if expired, silently catching errors so that the exposure detection can be performed
        try? context.awaitDispatch(Logic.Analytics.RefreshAnalyticsTokenIfExpired())

        // update analytics event without exposure opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateEventWithoutExposureOpportunityWindowIfNeeded())

        // update analytics dummy opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateDummyTrafficOpportunityWindowIfExpired())

        guard !isFirstLaunch else {
          // Nothing else to do if it's the first launch
          return
        }

        // Perform exposure detection if necessary
        context.dispatch(Logic.ExposureDetection.PerformExposureDetectionIfNecessary(type: .foreground))

        // updates the ingestion dummy traffic opportunity window if it expired
        try context.awaitDispatch(Logic.DataUpload.UpdateDummyTrafficOpportunityWindowIfExpired())

        // schedules a dummy sequence of ingestion requests for some point in the future
        try context.awaitDispatch(Logic.DataUpload.ScheduleDummyIngestionSequenceIfNecessary())
      }
    }

    /// Launched when app is about to enter in foreground
    struct WillEnterForeground: AppSideEffect, NotificationObserverDispatchable {
      init() {}

      init?(notification: Notification) {
        guard notification.name == UIApplication.willEnterForegroundNotification else {
          return nil
        }
      }

      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        // refresh statuses
        try context.awaitDispatch(RefreshAuthorizationStatuses())

        // clears `PositiveExposureResults` older than 14 days from the `ExposureDetectionState`
        try context.awaitDispatch(Logic.ExposureDetection.ClearOutdatedResults(now: context.dependencies.now()))

        // Removes notifications as the user has opened the app
        context.dispatch(Logic.CovidStatus.RemoveRiskReminderNotification())

        // check whether to show force update
        try context.awaitDispatch(ForceUpdate.CheckAppVersion())

        // refresh the analytics token if expired, silently catching errors so that the exposure detection can be performed
        try? context.awaitDispatch(Logic.Analytics.RefreshAnalyticsTokenIfExpired())

        // update analytics event without exposure opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateEventWithoutExposureOpportunityWindowIfNeeded())

        // update analytics dummy opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateDummyTrafficOpportunityWindowIfExpired())

        // Perform exposure detection if necessary
        context.dispatch(Logic.ExposureDetection.PerformExposureDetectionIfNecessary(type: .foreground))

        // updates the ingestion dummy traffic opportunity window if it expired
        try context.awaitDispatch(Logic.DataUpload.UpdateDummyTrafficOpportunityWindowIfExpired())

        // schedules a dummy sequence of ingestion requests for some point in the future
        try context.awaitDispatch(Logic.DataUpload.ScheduleDummyIngestionSequenceIfNecessary())
      }
    }

    /// Launched when app did become active.
    /// Note that when the app is in foreground and the command center is opened / closed, `didBecomeActiveNotification`
    /// will be dispatched, but not `willEnterForegroundNotification`.
    struct DidBecomeActive: AppSideEffect, NotificationObserverDispatchable {
      init() {}

      init?(notification: Notification) {
        guard notification.name == UIApplication.didBecomeActiveNotification else {
          return nil
        }
      }

      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        // dismiss sensitive data overlay. Check `SensitiveDataCoverVC` documentation.
        context.dispatch(Logic.Shared.HideSensitiveDataCoverIfPresent())

        // refresh statuses
        try context.awaitDispatch(RefreshAuthorizationStatuses())
      }
    }

    /// Launched when app will resign active.
    struct WillResignActive: AppSideEffect, NotificationObserverDispatchable {
      init() {}

      init?(notification: Notification) {
        guard notification.name == UIApplication.willResignActiveNotification else {
          return nil
        }
      }

      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        // show sensitive data overlay. Check `SensitiveDataCoverVC` documentation.
        context.dispatch(Logic.Shared.ShowSensitiveDataCoverIfNeeded())
      }
    }

    /// Launched when the app entered background
    struct DidEnterBackground: AppSideEffect, NotificationObserverDispatchable {
      init() {}

      init?(notification: Notification) {
        guard notification.name == UIApplication.didEnterBackgroundNotification else {
          return nil
        }
      }

      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        // resets the state related to dummy sessions
        try context.awaitDispatch(Logic.DataUpload.MarkForegroundSessionFinished())
      }
    }

    /// Performed when the system launches the app in the background to run the exposure detection task.
    struct HandleExposureDetectionBackgroundTask: AppSideEffect {
      /// The background task that dispatched this SideEffect
      var task: BackgroundTask

      func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
        // clears `PositiveExposureResults` older than 14 days from the `ExposureDetectionState`
        try context.awaitDispatch(Logic.ExposureDetection.ClearOutdatedResults(now: context.dependencies.now()))

        // refresh the analytics token if expired, silently catching errors so that the exposure detection can be performed
        try? context.awaitDispatch(Logic.Analytics.RefreshAnalyticsTokenIfExpired())

        // update analytics event without exposure opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateEventWithoutExposureOpportunityWindowIfNeeded())

        // update analytics dummy opportunity window if expired
        try context.awaitDispatch(Logic.Analytics.UpdateDummyTrafficOpportunityWindowIfExpired())

        // updates the ingestion dummy traffic opportunity window if it expired
        try context.awaitDispatch(Logic.DataUpload.UpdateDummyTrafficOpportunityWindowIfExpired())

        // Update the configuration, with a timeout. Continue in any case in order not to waste an Exposure Detection cycle.
        try? await(context.dispatch(Logic.Configuration.DownloadAndUpdateConfiguration()).timeout(timeout: 10))

        // Dispatch the exposure detection
        context.dispatch(Logic.ExposureDetection.PerformExposureDetectionIfNecessary(type: .background(self.task)))
      }
    }
  }
}

// MARK: Helper Side Effects

extension Logic.Lifecycle {
  struct PerformFirstLaunchSetupIfNeeded: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()

      guard !state.toggles.isFirstLaunchSetupPerformed else {
        // The first launch setup was already performed
        return
      }

      // Download the Configuration with a given timeout
      let configurationFetch = context
        .dispatch(Logic.Configuration.DownloadAndUpdateConfiguration())
        .timeout(timeout: 10)

      // Fail silently in case of error (for example, the timeout triggering)
      try? await(configurationFetch)

      /// Initialize the stochastic parameters required for the generation of dummy ingestion traffic.
      try context.awaitDispatch(Logic.DataUpload.UpdateDummyTrafficOpportunityWindow())

      // flags the first launch as done to prevent further downloads during the startup phase
      try context.awaitDispatch(PassFirstLaunchExecuted())
    }
  }

  struct RefreshAuthorizationStatuses: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let pushStatus = try await(context.dependencies.pushNotification.getCurrentAuthorizationStatus())
      let exposureStatus = try await(context.dependencies.exposureNotificationManager.getStatus())

      try context.awaitDispatch(UpdateAuthorizationStatus(
        pushNotificationAuthorizationStatus: pushStatus,
        exposureNotificationAuthorizationStatus: exposureStatus
      ))
    }
  }
}

// MARK: Private State Updaters

private extension Logic.Lifecycle {
  /// Update and store the app name used in the application using the bundle's display name
  private struct SetAppName: AppStateUpdater {
    let appName: String

    func updateState(_ state: inout AppState) {
      state.environment.appName = self.appName
    }
  }

  /// Update and store the app version
  private struct SetAppVersion: AppStateUpdater {
    let appVersion: String

    func updateState(_ state: inout AppState) {
      state.environment.appVersion = self.appVersion
    }
  }

  /// Updates the authorization statuses
  private struct UpdateAuthorizationStatus: AppStateUpdater {
    let pushNotificationAuthorizationStatus: PushNotificationStatus
    let exposureNotificationAuthorizationStatus: ExposureNotificationStatus

    func updateState(_ state: inout AppState) {
      state.environment.pushNotificationAuthorizationStatus = self.pushNotificationAuthorizationStatus
      state.environment.exposureNotificationAuthorizationStatus = self.exposureNotificationAuthorizationStatus
    }
  }

  /// Update the user language
  private struct SetUserLanguage: AppStateUpdater {
    let language: UserLanguage

    func updateState(_ state: inout AppState) {
      state.environment.userLanguage = self.language
    }
  }

  /// Marks the first launch executed as done
  struct PassFirstLaunchExecuted: AppStateUpdater {
    func updateState(_ state: inout AppState) {
      state.toggles.isFirstLaunchSetupPerformed = true
    }
  }
}

// MARK: - Helpers

extension UIApplication {
  var isForeground: Bool {
    mainThread {
      self.applicationState == .active
    }
  }
}
