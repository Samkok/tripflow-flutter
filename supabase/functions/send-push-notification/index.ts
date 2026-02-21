// Supabase Edge Function: send-push-notification
// Called by a Supabase Database Webhook on notifications table INSERT
// Fetches device tokens for the recipient and dispatches via FCM HTTP v1 API

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// ============================================================================
// Types
// ============================================================================

interface NotificationRecord {
  id: string;
  user_id: string;
  type: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  is_read: boolean;
  read_at: string | null;
  created_at: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: NotificationRecord;
  old_record: NotificationRecord | null;
}

interface DeviceToken {
  id: string;
  fcm_token: string;
  platform: "ios" | "android";
}

interface FirebaseServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  private_key_id: string;
  type: string;
}

// ============================================================================
// Supabase client (service role — reads device_tokens across all users)
// ============================================================================

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, supabaseServiceRoleKey);

// ============================================================================
// FCM OAuth2 helpers (FCM HTTP v1 requires a short-lived access token)
// ============================================================================

/**
 * Converts a PEM-encoded private key string into a DER ArrayBuffer
 * that can be imported by crypto.subtle.
 */
function pemToDer(pem: string): ArrayBuffer {
  // Strip PEM header/footer and newlines
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\n/g, "")
    .trim();

  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * Base64url-encodes a string or Uint8Array (no padding, URL-safe chars).
 */
function base64url(data: string | Uint8Array): string {
  let str: string;
  if (typeof data === "string") {
    str = btoa(data);
  } else {
    str = btoa(String.fromCharCode(...data));
  }
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

/**
 * Mints a Google OAuth2 access token using a service account private key.
 * Uses RSA-SHA256 JWT assertion (RFC 7523) — required for FCM HTTP v1 API.
 */
async function getFcmAccessToken(
  serviceAccount: FirebaseServiceAccount
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  // Build JWT header and payload
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({
      iss: serviceAccount.client_email,
      sub: serviceAccount.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    })
  );

  const signingInput = `${header}.${payload}`;

  // Import the RSA private key
  const privateKeyDer = pemToDer(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  // Sign the JWT
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput)
  );

  const jwt = `${signingInput}.${base64url(new Uint8Array(signature))}`;

  // Exchange JWT for access token
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!tokenResponse.ok) {
    const body = await tokenResponse.text();
    throw new Error(`Failed to get FCM access token: ${tokenResponse.status} ${body}`);
  }

  const tokenData = await tokenResponse.json();
  return tokenData.access_token as string;
}

// ============================================================================
// FCM dispatch
// ============================================================================

/**
 * Sends a push notification to a single FCM device token via HTTP v1 API.
 * Returns the FCM error code if the token is invalid/unregistered.
 */
async function sendFcmMessage(
  accessToken: string,
  projectId: string,
  fcmToken: string,
  notification: NotificationRecord
): Promise<string | null> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  // Flatten notification.data to Record<string, string> for FCM (FCM data values must be strings)
  const dataPayload: Record<string, string> = {
    type: notification.type,
    notification_id: notification.id,
  };
  for (const [key, value] of Object.entries(notification.data ?? {})) {
    dataPayload[key] = String(value);
  }

  const message = {
    message: {
      token: fcmToken,
      notification: {
        title: notification.title,
        body: notification.body,
      },
      data: dataPayload,
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
      android: {
        priority: "high",
      },
    },
  };

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(message),
  });

  if (response.ok) {
    return null; // success
  }

  const errorBody = await response.json().catch(() => ({}));
  const errorCode = errorBody?.error?.details?.[0]?.errorCode as string | undefined;

  console.error(`FCM error for token ${fcmToken.slice(-8)}:`, {
    status: response.status,
    errorCode,
    error: errorBody?.error?.message,
  });

  return errorCode ?? "UNKNOWN_ERROR";
}

/**
 * Marks a device token as inactive in the database.
 * Called when FCM returns UNREGISTERED (app uninstalled) or INVALID_ARGUMENT.
 */
async function deactivateToken(fcmToken: string): Promise<void> {
  const { error } = await supabase
    .from("device_tokens")
    .update({ is_active: false, updated_at: new Date().toISOString() })
    .eq("fcm_token", fcmToken);

  if (error) {
    console.error("Failed to deactivate token:", error.message);
  } else {
    console.log(`Token deactivated (device uninstalled): ...${fcmToken.slice(-8)}`);
  }
}

// ============================================================================
// Main handler
// ============================================================================

serve(async (req) => {
  try {
    console.log("send-push-notification: Webhook received");

    // 1. Parse the Database Webhook payload
    let payload: WebhookPayload;
    try {
      payload = await req.json();
    } catch (e) {
      console.error("Invalid JSON payload:", e);
      return new Response(JSON.stringify({ error: "Invalid JSON" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Only handle INSERT events (new notifications)
    if (payload.type !== "INSERT") {
      console.log("Ignoring non-INSERT webhook event:", payload.type);
      return new Response(
        JSON.stringify({ message: "Ignored — only INSERT events trigger push notifications" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const notification = payload.record;

    console.log("Processing notification:", {
      id: notification.id,
      user_id: notification.user_id,
      type: notification.type,
    });

    // 2. Fetch active device tokens for this user
    const { data: tokens, error: tokensError } = await supabase
      .from("device_tokens")
      .select("id, fcm_token, platform")
      .eq("user_id", notification.user_id)
      .eq("is_active", true);

    if (tokensError) {
      console.error("Failed to fetch device tokens:", tokensError.message);
      return new Response(
        JSON.stringify({ error: "DB error fetching tokens", details: tokensError.message }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    if (!tokens || tokens.length === 0) {
      console.log(`No active device tokens for user ${notification.user_id} — skipping push`);
      return new Response(
        JSON.stringify({ message: "No active device tokens for user" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    console.log(`Found ${tokens.length} active device token(s) for user`);

    // 3. Load Firebase service account and get FCM access token
    const serviceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
    if (!serviceAccountJson) {
      console.error("FIREBASE_SERVICE_ACCOUNT_JSON environment variable not set");
      return new Response(
        JSON.stringify({ error: "Firebase service account not configured" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    let serviceAccount: FirebaseServiceAccount;
    try {
      serviceAccount = JSON.parse(serviceAccountJson);
    } catch (e) {
      console.error("Failed to parse FIREBASE_SERVICE_ACCOUNT_JSON:", e);
      return new Response(
        JSON.stringify({ error: "Invalid Firebase service account JSON" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    let accessToken: string;
    try {
      accessToken = await getFcmAccessToken(serviceAccount);
      console.log("FCM access token obtained successfully");
    } catch (e) {
      console.error("Failed to get FCM access token:", e);
      return new Response(
        JSON.stringify({ error: "Failed to authenticate with FCM", details: String(e) }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    // 4. Send push notification to each device token
    let successCount = 0;
    let failureCount = 0;

    for (const tokenRow of tokens as DeviceToken[]) {
      const errorCode = await sendFcmMessage(
        accessToken,
        serviceAccount.project_id,
        tokenRow.fcm_token,
        notification
      );

      if (errorCode === null) {
        successCount++;
        console.log(
          `Push sent successfully to ${tokenRow.platform} device (...${tokenRow.fcm_token.slice(-8)})`
        );
      } else {
        failureCount++;

        // Deactivate tokens that are no longer valid
        if (errorCode === "UNREGISTERED" || errorCode === "INVALID_ARGUMENT") {
          await deactivateToken(tokenRow.fcm_token);
        }
      }
    }

    console.log(`Push dispatch complete: ${successCount} sent, ${failureCount} failed`);

    return new Response(
      JSON.stringify({
        message: "Push notifications dispatched",
        notification_id: notification.id,
        notification_type: notification.type,
        tokens_total: tokens.length,
        tokens_success: successCount,
        tokens_failed: failureCount,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Unhandled error in send-push-notification:", error);
    return new Response(
      JSON.stringify({
        error: "Internal server error",
        details: error instanceof Error ? error.message : String(error),
      }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
