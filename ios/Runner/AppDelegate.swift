import AppTrackingTransparency
import FBSDKCoreKit
import Flutter
import UIKit
import GoogleMaps
import Firebase

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let metaAds = MetaAdsBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Initialize Firebase (required for FCM push notifications)
    FirebaseApp.configure()

    // Initialize Google Maps with API key
    GMSServices.provideAPIKey("AIzaSyDuBPtEpO7gM7409RVrkTkXWimCKmNkgw8")

    GeneratedPluginRegistrant.register(with: self)

    // Ads measurement. Only listens here; Meta's SDK starts when Dart says
    // the person has allowed it (see MetaAdsBridge below).
    if let bridgeRegistrar = self.registrar(forPlugin: "MetaAdsBridge") {
      metaAds.attach(to: bridgeRegistrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Links that open the app. Both overrides hand everything on to Flutter's
  // plugins exactly as before; the bridge only looks at links from a Meta ad.
  // If the app ever moves to the UIScene lifecycle these stop being called
  // and the same two lines belong in the scene delegate.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    metaAds.noteOpened(url, options: options)
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      metaAds.noteOpened(url, options: [:])
    }
    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }
}

/// The app's only connection to Meta's SDK (ads measurement) and to Apple's
/// tracking prompt. The Dart side is lib/services/meta_ads_bridge.dart.
///
/// Meta's SDK does NOT start with the app. Until `start` is called it has
/// made no request and stored nothing on the device. Dart calls `start`
/// only once the person has agreed to ads measurement (or, outside the
/// consent regions, has been shown the notice), and `stop` the moment they
/// withdraw.
///
/// This is deliberately not the facebook_app_events plugin: that initialises
/// the SDK at launch for everyone, including people who refuse, and hands
/// it every link the app is opened with.
final class MetaAdsBridge {
  /// The SDK has been initialised in this process. There is no way back.
  private var initialized = false

  /// Ads measurement is on: events are being logged.
  private var started = false

  /// A link from a Meta ad that arrived before measurement started. Kept in
  /// memory only, and dropped unless measurement starts during this run.
  private var pendingAdLink: (url: URL, options: [UIApplication.OpenURLOptionsKey: Any])?

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "voyza/meta_ads", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      start(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "setTrackingAllowed":
      // The system's answer is the truth; the argument is not needed.
      if initialized {
        Settings.shared.isAdvertiserTrackingEnabled = Self.trackingAuthorized
      }
      result(nil)
    case "logEvent":
      logEvent(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "logPurchase":
      logPurchase(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "anonymousId":
      // Meta's install identifier, handed to RevenueCat so the purchases it
      // reports from its servers can be matched to this install. None
      // until the SDK has been started with the person's agreement.
      result(initialized ? AppEvents.shared.anonymousID : nil)
    case "deviceRegion":
      result(Self.deviceRegion)
    case "trackingStatus":
      result(Self.name(of: ATTrackingManager.trackingAuthorizationStatus))
    case "requestTracking":
      ATTrackingManager.requestTrackingAuthorization { status in
        DispatchQueue.main.async { result(Self.name(of: status)) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ arguments: [String: Any]) {
    // SDK 18 still defaults to a Graph API version Meta has retired. Named
    // before initialising so the SDK's first request uses it.
    if let version = arguments["graphApiVersion"] as? String {
      Settings.shared.graphAPIVersion = version
    }
    if !initialized {
      ApplicationDelegate.shared.initializeSDK()
      initialized = true
    }
    // Debug builds only: the SDK says in the Xcode console what it records
    // and whether Meta accepted it ("FBSDKAppEvents: Flushed ... - Success").
    if arguments["debugLogging"] as? Bool == true {
      Settings.shared.enableLoggingBehavior(.appEvents)
    }

    // Before anything is sent: Limited Data Use travels with every event.
    Settings.shared.setDataProcessingOptions(
      arguments["dataProcessingOptions"] as? [String] ?? [],
      country: Int32(clamping: arguments["dataProcessingCountry"] as? Int ?? 0),
      state: Int32(clamping: arguments["dataProcessingState"] as? Int ?? 0)
    )
    // Read by the SDK on iOS 15 and 16; from iOS 17 it asks the system itself.
    Settings.shared.isAdvertiserTrackingEnabled = Self.trackingAuthorized
    Settings.shared.isAdvertiserIDCollectionEnabled = true
    Settings.shared.isAutoLogAppEventsEnabled = true
    // Reports the install (once per install) and starts counting sessions.
    AppEvents.shared.activateApp()
    started = true

    if let link = pendingAdLink {
      pendingAdLink = nil
      ApplicationDelegate.shared.application(
        UIApplication.shared,
        open: link.url,
        options: link.options
      )
    }
  }

  private func stop() {
    started = false
    pendingAdLink = nil
    // Never started in this process: nothing of Meta's is running.
    guard initialized else { return }
    Settings.shared.isAutoLogAppEventsEnabled = false
    Settings.shared.isAdvertiserIDCollectionEnabled = false
  }

  /// A link the app was opened with. Only a link from a Meta ad carries
  /// `al_applink_data`; Meta uses it to credit the ad. Nothing else the app
  /// is opened with (trip links, password resets) is shown to the SDK.
  func noteOpened(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
    guard Self.isFromMetaAd(url) else { return }
    if started {
      ApplicationDelegate.shared.application(UIApplication.shared, open: url, options: options)
    } else {
      pendingAdLink = (url, options)
    }
  }

  private func logEvent(_ arguments: [String: Any]) {
    guard started, let name = arguments["name"] as? String else { return }
    let parameters = Self.parameters(arguments["parameters"])
    if let valueToSum = arguments["valueToSum"] as? Double {
      AppEvents.shared.logEvent(
        AppEvents.Name(name),
        valueToSum: valueToSum,
        parameters: parameters
      )
    } else {
      AppEvents.shared.logEvent(AppEvents.Name(name), parameters: parameters)
    }
  }

  private func logPurchase(_ arguments: [String: Any]) {
    guard
      started,
      let amount = arguments["amount"] as? Double,
      let currency = arguments["currency"] as? String
    else { return }
    AppEvents.shared.logPurchase(
      amount: amount,
      currency: currency,
      parameters: Self.parameters(arguments["parameters"])
    )
  }

  private static func parameters(_ raw: Any?) -> [AppEvents.ParameterName: Any] {
    var parameters: [AppEvents.ParameterName: Any] = [:]
    for (key, value) in raw as? [String: Any] ?? [:] {
      parameters[AppEvents.ParameterName(key)] = value
    }
    return parameters
  }

  private static func isFromMetaAd(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .contains { $0.name == "al_applink_data" } ?? false
  }

  /// The Region chosen in iOS Settings. Since iOS 16 this is NOT the country
  /// in the language Flutter reports: with Region set to France the locale
  /// reads "en_KH@rg=frzzzz", language still "English (Cambodia)". The
  /// consent rules need the region itself.
  private static var deviceRegion: String? {
    if #available(iOS 16, *) {
      return Locale.current.region?.identifier
    }
    return Locale.current.regionCode
  }

  private static var trackingAuthorized: Bool {
    ATTrackingManager.trackingAuthorizationStatus == .authorized
  }

  private static func name(of status: ATTrackingManager.AuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .authorized: return "authorized"
    case .denied: return "denied"
    @unknown default: return "denied"
    }
  }
}
