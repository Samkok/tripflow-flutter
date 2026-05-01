# =====================================================================
# ProGuard / R8 rules for VoyZa release builds.
#
# Most Flutter plugins ship their own consumer rules (consumerProguardFiles
# in their AAR), so this file only needs entries for libraries that rely on
# reflection or runtime class lookups not covered by their consumer rules.
#
# After changing rules, do a clean release build and exercise:
#   - Sign-in / sign-up
#   - Adding + viewing a trip and its locations
#   - Photo gallery (CachedNetworkImage)
#   - Push notification receipt
#   - Subscription purchase / restore (RevenueCat)
# =====================================================================

# ---- Flutter framework ----------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# ---- Kotlin metadata (used by reflection in some libs) --------------
-keep class kotlin.Metadata { *; }
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions, EnclosingMethod

# ---- Hive (uses generated TypeAdapters; we register them manually) --
# Keep all classes referenced from generated *.g.dart adapters by their
# raw names. Hive's binary format keys fields by integer id, so member
# renaming is safe — but the adapter code calls model getters/setters
# directly, so the model classes themselves must keep their methods.
-keep class * extends hive.TypeAdapter { *; }
-keep @hive.HiveType class * { *; }
-keepclassmembers class * {
    @hive.HiveField <fields>;
}

# ---- Supabase / GoTrue / Postgrest (uses Gson / json reflection) ----
-keep class io.supabase.** { *; }
-keep class com.supabase.** { *; }
-dontwarn io.supabase.**

# ---- Firebase / FCM -------------------------------------------------
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ---- RevenueCat -----------------------------------------------------
-keep class com.revenuecat.purchases.** { *; }
-dontwarn com.revenuecat.purchases.**

# ---- Google Maps Flutter / Places -----------------------------------
-keep class com.google.android.libraries.maps.** { *; }
-keep class com.google.maps.** { *; }
-dontwarn com.google.android.libraries.maps.**

# ---- Geolocator / permission_handler --------------------------------
-keep class com.baseflow.** { *; }
-dontwarn com.baseflow.**

# ---- Connectivity / url_launcher / share_plus -----------------------
-keep class io.flutter.plugins.** { *; }

# ---- OkHttp / Dio --------------------------------------------------
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**

# ---- Strip noisy log calls in release (defense-in-depth alongside
#      the print -> debugPrint migration in Dart code). --------------
-assumenosideeffects class android.util.Log {
    public static *** v(...);
    public static *** d(...);
    public static *** i(...);
}

# ---- Generic safety: keep model classes that may be (de)serialized --
# Riverpod / json maps use reflection-free codegen, but third-party libs
# may inspect annotations. Keep public members of any *.models.* class.
-keep class **.models.** { *; }
-keep class com.superiordev.voyza.** { *; }
