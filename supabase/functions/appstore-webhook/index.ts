// Supabase Edge Function: App Store Server Notification Handler
// Handles Apple subscription lifecycle events and updates user_subscriptions table
// Verifies Apple JWS (JSON Web Signature) before processing any event
//
// Apple ASSN v2 docs:
//   https://developer.apple.com/documentation/appstoreservernotifications

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import * as x509 from "https://esm.sh/@peculiar/x509@1.9.3";

// ============================================================================
// Types
// ============================================================================

interface AppStoreNotificationPayload {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  version: string;
  signedDate: number;
  data: {
    bundleId: string;
    bundleVersion?: string;
    environment: string;
    signedTransactionInfo: string;
    signedRenewalInfo?: string;
  };
}

interface JWSTransactionDecodedPayload {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  appAccountToken?: string;     // Supabase user UUID (set by RevenueCat)
  purchaseDate: number;         // milliseconds
  originalPurchaseDate: number; // milliseconds
  expiresDate?: number;         // milliseconds
  quantity: number;
  type: string;
  offerType?: number;           // 1=intro, 2=promo, 3=offer_code
  inAppOwnershipType: string;
  transactionReason?: string;
  storefront?: string;
  environment: string;
}

interface JWSRenewalInfoDecodedPayload {
  autoRenewProductId?: string;
  autoRenewStatus: number;   // 1=will renew, 0=will not renew
  expirationIntent?: number; // 1=voluntary, 2=billing, 3=price increase, 4=not available
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
  productId: string;
  signedDate: number;
  environment: string;
}

interface SubscriptionUpdate {
  status: 'active' | 'expired' | 'grace_period' | 'billing_retry' | 'cancelled';
  willRenew: boolean;
  expiresAt: string | null;
  purchaseDate: string | null;
  periodType: string;
  billingIssuesDetectedAt: string | null;
  unsubscribeDetectedAt: string | null;
}

// ============================================================================
// Configuration
// ============================================================================

// Apple Root CA G3 SHA-256 fingerprint — hardcoded to verify the cert chain
// Source: https://www.apple.com/certificateauthority/
const APPLE_ROOT_CA_G3_FINGERPRINT =
  "63343afee607d8427b40bd7dc44a0354a5f72e36e40c62d7b4e7740e2ef3dc5b";

const APP_BUNDLE_ID = "com.superiordev.voyza";
const ENTITLEMENT = "premium";
const STORE = "app_store";

// Supabase client with service role (bypasses RLS for webhook writes)
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ============================================================================
// JWS Verification Helpers
// ============================================================================

function base64urlToBytes(str: string): Uint8Array {
  const padded = str + "=".repeat((4 - (str.length % 4)) % 4);
  const base64 = padded.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function base64urlDecode(str: string): string {
  return new TextDecoder().decode(base64urlToBytes(str));
}

async function getCertFingerprint(cert: x509.X509Certificate): Promise<string> {
  const hashBuffer = await crypto.subtle.digest("SHA-256", cert.rawData);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Verifies an Apple JWS token and returns the decoded payload.
 *
 * Steps:
 *  1. Parse x5c certificate chain from JWS header
 *  2. Confirm the root cert matches Apple Root CA G3 (fingerprint check)
 *  3. Verify each cert is signed by the next in the chain
 *  4. Verify the JWS signature against the leaf cert's ECDSA public key
 *  5. Decode and return the payload
 *
 * Apple uses ES256 (ECDSA P-256, SHA-256). The signature in a JWS is in
 * IEEE P1363 format (r||s), which is what crypto.subtle.verify expects.
 */
async function verifyAndDecodeJWS(jws: string): Promise<unknown> {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error("Invalid JWS format — expected 3 dot-separated parts");
  }

  const [headerB64u, payloadB64u, signatureB64u] = parts;

  // Parse JWS header
  const header = JSON.parse(base64urlDecode(headerB64u));

  if (header.alg !== "ES256") {
    throw new Error(`Unexpected JWS algorithm: ${header.alg} (expected ES256)`);
  }

  if (!header.x5c || !Array.isArray(header.x5c) || header.x5c.length === 0) {
    throw new Error("JWS header missing x5c certificate chain");
  }

  // Parse x5c: each entry is standard base64 (not base64url)
  const certs: x509.X509Certificate[] = header.x5c.map((certB64: string) => {
    const der = Uint8Array.from(atob(certB64), (c) => c.charCodeAt(0));
    return new x509.X509Certificate(der);
  });

  // Step 1: Verify root certificate is Apple Root CA G3
  const rootCert = certs[certs.length - 1];
  const rootFingerprint = await getCertFingerprint(rootCert);
  if (rootFingerprint !== APPLE_ROOT_CA_G3_FINGERPRINT) {
    throw new Error(
      `Root certificate is not Apple Root CA G3. Got fingerprint: ${rootFingerprint}`,
    );
  }

  // Step 2: Verify certificate chain (leaf → intermediate → root)
  for (let i = 0; i < certs.length - 1; i++) {
    const isValid = await certs[i].verify({ publicKey: certs[i + 1].publicKey });
    if (!isValid) {
      throw new Error(`Certificate chain verification failed at index ${i}`);
    }
  }

  // Step 3: Verify JWS signature using leaf certificate's public key
  const leafPublicKey = await certs[0].publicKey.export();
  const message = new TextEncoder().encode(`${headerB64u}.${payloadB64u}`);
  const signature = base64urlToBytes(signatureB64u);

  const isValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafPublicKey,
    signature,
    message,
  );

  if (!isValid) {
    throw new Error("JWS signature verification failed");
  }

  return JSON.parse(base64urlDecode(payloadB64u));
}

// ============================================================================
// Utility Helpers
// ============================================================================

function msToIso(ms: number | undefined): string | null {
  return ms != null ? new Date(ms).toISOString() : null;
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(str);
}

function mapOfferTypeToPeriodType(offerType?: number): string {
  switch (offerType) {
    case 1: return "intro";
    case 2: return "promotional";
    case 3: return "offer_code";
    default: return "normal";
  }
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ============================================================================
// 4 Subscription Event Handlers
// ============================================================================

/**
 * SUBSCRIBED, DID_RENEW, OFFER_REDEEMED
 * Subscription is newly active or renewed — clear any billing issues.
 */
function handleSubscriptionActivated(
  tx: JWSTransactionDecodedPayload,
): SubscriptionUpdate {
  console.log("handleSubscriptionActivated:", tx.productId);
  return {
    status: "active",
    willRenew: true,
    expiresAt: msToIso(tx.expiresDate),
    purchaseDate: msToIso(tx.purchaseDate),
    periodType: mapOfferTypeToPeriodType(tx.offerType),
    billingIssuesDetectedAt: null,  // clear any previous billing failure
    unsubscribeDetectedAt: null,    // clear any previous cancellation
  };
}

/**
 * DID_FAIL_TO_RENEW, DID_CHANGE_RENEWAL_STATUS (AUTO_RENEW_DISABLED)
 *
 * DID_FAIL_TO_RENEW + GRACE_PERIOD subtype → still active, billing issue flagged
 * DID_FAIL_TO_RENEW (no grace)             → immediately expired
 * AUTO_RENEW_DISABLED                      → still active, cancel intent recorded
 */
function handleSubscriptionCancelled(
  tx: JWSTransactionDecodedPayload,
  renewal: JWSRenewalInfoDecodedPayload | null,
  notificationType: string,
  subtype: string | undefined,
): SubscriptionUpdate {
  const now = new Date().toISOString();
  console.log(
    `handleSubscriptionCancelled: type=${notificationType} subtype=${subtype}`,
  );

  if (notificationType === "DID_CHANGE_RENEWAL_STATUS" &&
    subtype === "AUTO_RENEW_DISABLED") {
    // User turned off auto-renew — still active until expires_at
    return {
      status: "active",
      willRenew: false,
      expiresAt: msToIso(tx.expiresDate),
      purchaseDate: msToIso(tx.purchaseDate),
      periodType: mapOfferTypeToPeriodType(tx.offerType),
      billingIssuesDetectedAt: null,
      unsubscribeDetectedAt: now,
    };
  }

  // DID_FAIL_TO_RENEW
  const inGracePeriod = subtype === "GRACE_PERIOD" ||
    renewal?.isInBillingRetryPeriod === true;

  if (inGracePeriod && tx.expiresDate && tx.expiresDate > Date.now()) {
    // User is in the grace period — keep access, flag billing issue
    return {
      status: "active",
      willRenew: false,
      expiresAt: msToIso(tx.expiresDate),
      purchaseDate: msToIso(tx.purchaseDate),
      periodType: mapOfferTypeToPeriodType(tx.offerType),
      billingIssuesDetectedAt: now,
      unsubscribeDetectedAt: null,
    };
  }

  // No grace period — expired immediately due to billing failure
  return {
    status: "expired",
    willRenew: false,
    expiresAt: msToIso(tx.expiresDate),
    purchaseDate: msToIso(tx.purchaseDate),
    periodType: mapOfferTypeToPeriodType(tx.offerType),
    billingIssuesDetectedAt: now,
    unsubscribeDetectedAt: null,
  };
}

/**
 * EXPIRED, GRACE_PERIOD_EXPIRED, REVOKE
 * Subscription has fully ended — access is revoked.
 */
function handleSubscriptionExpired(
  tx: JWSTransactionDecodedPayload,
): SubscriptionUpdate {
  console.log("handleSubscriptionExpired:", tx.productId);
  return {
    status: "expired",
    willRenew: false,
    expiresAt: msToIso(tx.expiresDate),
    purchaseDate: msToIso(tx.purchaseDate),
    periodType: mapOfferTypeToPeriodType(tx.offerType),
    billingIssuesDetectedAt: null,
    unsubscribeDetectedAt: new Date().toISOString(),
  };
}

/**
 * REFUND
 * Apple issued a refund — revoke access immediately.
 */
function handleRefund(
  tx: JWSTransactionDecodedPayload,
): SubscriptionUpdate {
  console.log("handleRefund:", tx.productId);
  return {
    status: "expired",
    willRenew: false,
    expiresAt: msToIso(tx.expiresDate),
    purchaseDate: msToIso(tx.purchaseDate),
    periodType: mapOfferTypeToPeriodType(tx.offerType),
    billingIssuesDetectedAt: null,
    unsubscribeDetectedAt: new Date().toISOString(),
  };
}

// ============================================================================
// Main Handler
// ============================================================================

serve(async (req) => {
  try {
    console.log("App Store webhook received:", {
      method: req.method,
      url: req.url,
    });

    if (req.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    // 1. Parse outer body
    let body: { signedPayload?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "Invalid JSON body" }, 400);
    }

    if (!body.signedPayload) {
      return jsonResponse({ error: "Missing signedPayload field" }, 400);
    }

    // 2. Verify and decode outer JWS → notification payload
    let notification: AppStoreNotificationPayload;
    try {
      notification = await verifyAndDecodeJWS(
        body.signedPayload,
      ) as AppStoreNotificationPayload;
      console.log("Outer JWS verified. notificationType:", notification.notificationType);
    } catch (e) {
      console.error("Outer JWS verification failed:", e);
      return jsonResponse({ error: "JWS verification failed", detail: String(e) }, 401);
    }

    // 3. Validate bundle ID — reject notifications intended for other apps
    if (notification.data?.bundleId !== APP_BUNDLE_ID) {
      console.error("Bundle ID mismatch:", notification.data?.bundleId);
      return jsonResponse({
        error: "Bundle ID mismatch",
        expected: APP_BUNDLE_ID,
        received: notification.data?.bundleId,
      }, 400);
    }

    const { notificationType, subtype, notificationUUID } = notification;

    console.log("Processing notification:", {
      notificationType,
      subtype,
      notificationUUID,
      environment: notification.data.environment,
    });

    // 4. Handle TEST notification immediately (no transaction needed)
    if (notificationType === "TEST") {
      console.log("TEST notification received — acknowledging");
      return jsonResponse({
        message: "TEST notification received",
        notificationUUID,
      }, 200);
    }

    // 5. Route to handler or ignore
    const HANDLED_TYPES = [
      "SUBSCRIBED",
      "DID_RENEW",
      "OFFER_REDEEMED",
      "DID_CHANGE_RENEWAL_STATUS",
      "DID_FAIL_TO_RENEW",
      "EXPIRED",
      "GRACE_PERIOD_EXPIRED",
      "REVOKE",
      "REFUND",
    ];

    if (!HANDLED_TYPES.includes(notificationType)) {
      console.log("Ignoring non-handled notification type:", notificationType);
      return jsonResponse({ message: "Notification type ignored", notificationType }, 200);
    }

    // 6. Verify and decode inner signedTransactionInfo JWS
    let tx: JWSTransactionDecodedPayload;
    try {
      tx = await verifyAndDecodeJWS(
        notification.data.signedTransactionInfo,
      ) as JWSTransactionDecodedPayload;
      console.log("Transaction JWS verified:", {
        transactionId: tx.transactionId,
        productId: tx.productId,
        appAccountToken: tx.appAccountToken,
      });
    } catch (e) {
      console.error("signedTransactionInfo JWS verification failed:", e);
      return jsonResponse({
        error: "Transaction JWS verification failed",
        detail: String(e),
      }, 401);
    }

    // 7. Decode optional signedRenewalInfo (needed for grace period detection)
    let renewal: JWSRenewalInfoDecodedPayload | null = null;
    if (notification.data.signedRenewalInfo) {
      try {
        renewal = await verifyAndDecodeJWS(
          notification.data.signedRenewalInfo,
        ) as JWSRenewalInfoDecodedPayload;
      } catch (e) {
        // Non-fatal — log and continue without renewal info
        console.warn("signedRenewalInfo JWS decode failed (non-fatal):", e);
      }
    }

    // 8. Extract user ID from appAccountToken
    // RevenueCat sets this field to the Supabase user UUID on iOS 15+
    const userId = tx.appAccountToken;

    if (!userId || !isValidUUID(userId)) {
      console.warn(
        "Missing or invalid appAccountToken — cannot identify user. " +
        "This may be a legacy purchase (iOS <15) or a purchase made before RevenueCat linked the user ID.",
        { appAccountToken: userId, transactionId: tx.transactionId },
      );
      return jsonResponse({
        message: "Notification skipped — no valid appAccountToken to identify user",
        transactionId: tx.transactionId,
        notificationType,
      }, 200); // 200 so Apple doesn't retry (we can't recover without the user ID)
    }

    // 9. Route to the appropriate handler
    let update: SubscriptionUpdate;

    switch (notificationType) {
      case "SUBSCRIBED":
      case "DID_RENEW":
      case "OFFER_REDEEMED":
        update = handleSubscriptionActivated(tx);
        break;

      case "DID_CHANGE_RENEWAL_STATUS":
        if (subtype === "AUTO_RENEW_ENABLED") {
          // User re-enabled auto-renew — treat like activation
          update = handleSubscriptionActivated(tx);
          update.willRenew = true;
          update.unsubscribeDetectedAt = null;
        } else {
          // AUTO_RENEW_DISABLED
          update = handleSubscriptionCancelled(tx, renewal, notificationType, subtype);
        }
        break;

      case "DID_FAIL_TO_RENEW":
        update = handleSubscriptionCancelled(tx, renewal, notificationType, subtype);
        break;

      case "EXPIRED":
      case "GRACE_PERIOD_EXPIRED":
      case "REVOKE":
        update = handleSubscriptionExpired(tx);
        break;

      case "REFUND":
        update = handleRefund(tx);
        break;

      default:
        // Shouldn't reach here given HANDLED_TYPES check above
        return jsonResponse({ message: "Unhandled type", notificationType }, 200);
    }

    console.log("Subscription update determined:", {
      userId,
      status: update.status,
      willRenew: update.willRenew,
      expiresAt: update.expiresAt,
    });

    // 10. Upsert subscription in database
    const { error: rpcError } = await supabase.rpc("upsert_subscription_status", {
      p_user_id: userId,
      p_revenuecat_app_user_id: userId, // same UUID; RevenueCat links them
      p_status: update.status,
      p_entitlement: ENTITLEMENT,
      p_product_identifier: tx.productId,
      p_store: STORE,
      p_expires_at: update.expiresAt,
      p_period_type: update.periodType,
      p_purchase_date: update.purchaseDate,
      p_will_renew: update.willRenew,
      p_billing_issues_detected_at: update.billingIssuesDetectedAt,
      p_unsubscribe_detected_at: update.unsubscribeDetectedAt,
    });

    if (rpcError) {
      console.error("upsert_subscription_status RPC failed:", rpcError);
      return jsonResponse({
        error: "Database error",
        details: rpcError.message,
      }, 500);
    }

    console.log("Successfully processed notification:", {
      notificationType,
      userId,
      status: update.status,
      notificationUUID,
    });

    return jsonResponse({
      message: "Notification processed successfully",
      notificationType,
      userId,
      status: update.status,
    }, 200);

  } catch (err) {
    console.error("Unhandled error in appstore-webhook:", err);
    return jsonResponse({
      error: "Internal server error",
      details: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
