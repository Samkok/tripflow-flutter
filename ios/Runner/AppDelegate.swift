import Flutter
import UIKit
import GoogleMaps
import Firebase

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Initialize Firebase (required for FCM push notifications)
    FirebaseApp.configure()

    // Initialize Google Maps with API key
    GMSServices.provideAPIKey("AIzaSyDuBPtEpO7gM7409RVrkTkXWimCKmNkgw8")

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
