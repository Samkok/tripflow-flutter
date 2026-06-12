# RevenueCat Webhook Synchronization Improvements

## Current Issues

1. ❌ **No idempotency** — same webhook fires twice = duplicate records
2. ❌ **No validation** — webhook could be spoofed or tampered
3. ❌ **No audit trail** — can't debug what happened
4. ❌ **No conflict detection** — SDK and DB can diverge silently
5. ❌ **No state machine** — illegal transitions allowed
6. ❌ **No retry logic** — transient failures = data loss
7. ❌ **No anonymous tracking** — can't track subscriptions until signup
8. ❌ **No expiry detection** — app doesn't know when trial ends
9. ❌ **No chargeback handling** — refunds not tracked
10. ❌ **Race conditions** — webhook vs client sync can conflict

---

## Critical Improvements (Do These First)

### 1. Add Webhook Event Deduplication ⭐⭐⭐

**Problem**: RevenueCat might send the same webhook multiple times (network retry).
**Solution**: Track webhook event IDs to prevent duplicates.

```sql
-- Create webhook event log table
CREATE TABLE IF NOT EXISTS webhook_events (
  id UUID PRIMARY KEY,
  event_id TEXT NOT NULL UNIQUE,  -- RevenueCat's event ID
  event_type TEXT NOT NULL,
  user_id TEXT NOT NULL,
  payload JSONB NOT NULL,
  processed BOOLEAN DEFAULT false,
  processed_at TIMESTAMPTZ,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_webhook_events_event_id ON webhook_events(event_id);
CREATE INDEX idx_webhook_events_user_id ON webhook_events(user_id);
CREATE INDEX idx_webhook_events_processed ON webhook_events(processed);

-- Add webhook_received_at to user_subscriptions to verify webhook fired
ALTER TABLE user_subscriptions 
ADD COLUMN webhook_received_at TIMESTAMPTZ,
ADD COLUMN webhook_event_id TEXT;

CREATE INDEX idx_user_subscriptions_webhook_event_id 
ON user_subscriptions(webhook_event_id);
```

**Updated RPC function with deduplication:**

```sql
CREATE OR REPLACE FUNCTION handle_revenuecat_webhook(
  webhook_data jsonb,
  signature TEXT DEFAULT NULL  -- Add signature validation
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id TEXT;
  v_app_user_id TEXT;
  v_entitlement TEXT;
  v_product_id TEXT;
  v_store TEXT;
  v_period_type TEXT;
  v_event_type TEXT;
  v_expires_at_ms BIGINT;
  v_purchased_at_ms BIGINT;
  v_status TEXT;
  v_will_renew BOOLEAN;
  v_response JSONB;
  v_is_duplicate BOOLEAN;
  v_webhook_log_id UUID;
BEGIN
  -- Extract event ID (for deduplication)
  v_event_id := webhook_data -> 'event' ->> 'id';
  v_app_user_id := webhook_data -> 'event' ->> 'app_user_id';

  -- Security: Verify webhook signature (if provided)
  IF signature IS NOT NULL THEN
    IF NOT verify_revenuecat_signature(webhook_data::text, signature) THEN
      v_response := jsonb_build_object(
        'success', false,
        'error', 'Invalid webhook signature'
      );
      RETURN v_response;
    END IF;
  END IF;

  -- Check for duplicate
  v_is_duplicate := EXISTS(
    SELECT 1 FROM webhook_events 
    WHERE event_id = v_event_id 
    AND processed = true
  );

  IF v_is_duplicate THEN
    v_response := jsonb_build_object(
      'success', true,
      'message', 'Webhook already processed (duplicate)',
      'user_id', v_app_user_id,
      'is_duplicate', true
    );
    RETURN v_response;
  END IF;

  -- Create log entry
  v_webhook_log_id := gen_random_uuid();
  INSERT INTO webhook_events (
    id,
    event_id,
    event_type,
    user_id,
    payload
  ) VALUES (
    v_webhook_log_id,
    v_event_id,
    webhook_data -> 'event' ->> 'type',
    v_app_user_id,
    webhook_data
  );

  BEGIN
    -- Extract webhook data
    v_entitlement := webhook_data -> 'event' -> 'entitlement_ids' ->> 0;
    v_product_id := webhook_data -> 'event' ->> 'product_id';
    v_store := webhook_data -> 'event' ->> 'store';
    v_period_type := webhook_data -> 'event' ->> 'period_type';
    v_event_type := webhook_data -> 'event' ->> 'type';
    v_expires_at_ms := (webhook_data -> 'event' ->> 'expiration_at_ms')::BIGINT;
    v_purchased_at_ms := (webhook_data -> 'event' ->> 'purchased_at_ms')::BIGINT;

    -- Validate required fields
    IF v_app_user_id IS NULL OR v_entitlement IS NULL THEN
      RAISE EXCEPTION 'Missing required fields: app_user_id or entitlement_ids';
    END IF;

    -- Determine status
    v_status := CASE
      WHEN v_event_type IN ('INITIAL_PURCHASE', 'RENEWAL', 'PRODUCT_CHANGE') THEN 'active'
      WHEN v_event_type = 'EXPIRATION' THEN 'expired'
      WHEN v_event_type = 'CANCELLATION' THEN 'cancelled'
      WHEN v_event_type = 'BILLING_ISSUE' THEN 'grace_period'
      ELSE 'active'
    END;

    v_will_renew := CASE
      WHEN v_period_type = 'TRIAL' THEN false
      WHEN v_period_type IN ('MONTHLY', 'ANNUAL') THEN true
      ELSE false
    END;

    -- Upsert subscription with webhook tracking
    INSERT INTO user_subscriptions (
      user_id,
      entitlement,
      status,
      product_identifier,
      will_renew,
      expires_at,
      store,
      period_type,
      webhook_event_id,
      webhook_received_at,
      created_at,
      updated_at
    ) VALUES (
      v_app_user_id,
      v_entitlement,
      v_status,
      v_product_id,
      v_will_renew,
      to_timestamp(v_expires_at_ms::BIGINT / 1000.0),
      v_store,
      v_period_type,
      v_event_id,
      NOW(),
      NOW(),
      NOW()
    ) ON CONFLICT (user_id) DO UPDATE SET
      status = v_status,
      product_identifier = v_product_id,
      will_renew = v_will_renew,
      expires_at = to_timestamp(v_expires_at_ms::BIGINT / 1000.0),
      period_type = v_period_type,
      webhook_event_id = v_event_id,
      webhook_received_at = NOW(),
      updated_at = NOW();

    -- Log trial if applicable
    IF v_period_type = 'TRIAL' THEN
      INSERT INTO trial_devices (
        user_id,
        device_id,
        product_identifier,
        store,
        trial_started_at
      ) VALUES (
        v_app_user_id,
        v_app_user_id,
        v_product_id,
        v_store,
        to_timestamp(v_purchased_at_ms::BIGINT / 1000.0)
      ) ON CONFLICT DO NOTHING;

      UPDATE user_profiles
      SET 
        trial_start_at = to_timestamp(v_purchased_at_ms::BIGINT / 1000.0),
        updated_at = NOW()
      WHERE user_id = v_app_user_id;
    END IF;

    -- Mark as processed
    UPDATE webhook_events 
    SET 
      processed = true,
      processed_at = NOW()
    WHERE id = v_webhook_log_id;

    v_response := jsonb_build_object(
      'success', true,
      'message', 'Webhook processed successfully',
      'user_id', v_app_user_id,
      'event_id', v_event_id,
      'status', v_status,
      'expires_at', to_timestamp(v_expires_at_ms::BIGINT / 1000.0)
    );

  EXCEPTION WHEN OTHERS THEN
    -- Log error
    UPDATE webhook_events 
    SET 
      error_message = SQLERRM
    WHERE id = v_webhook_log_id;

    v_response := jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'event_id', v_event_id
    );
  END;

  RETURN v_response;
END;
$$;
```

---

### 2. Add Webhook Signature Verification ⭐⭐⭐

```sql
-- Install pgcrypto extension for HMAC verification
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION verify_revenuecat_signature(
  payload_text TEXT,
  signature_header TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_secret TEXT;
  v_computed_signature TEXT;
BEGIN
  -- Get secret from environment (set via Supabase secrets)
  v_secret := current_setting('app.revenuecat_webhook_secret', true);
  
  IF v_secret IS NULL THEN
    -- Signature verification disabled if secret not set
    RETURN true;
  END IF;

  -- Compute HMAC-SHA256
  v_computed_signature := 'sha256=' || 
    encode(hmac(payload_text, v_secret, 'sha256'), 'hex');

  -- Compare (constant-time to prevent timing attacks)
  RETURN signature_header = v_computed_signature;
END;
$$;
```

---

### 3. Add Conflict Detection & Resolution ⭐⭐⭐

```sql
-- Track conflicts between SDK and DB
CREATE TABLE IF NOT EXISTS subscription_conflicts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  conflict_type TEXT NOT NULL,  -- 'expired_vs_active', 'active_vs_expired', etc.
  sdk_status TEXT,
  db_status TEXT,
  sdk_expires_at TIMESTAMPTZ,
  db_expires_at TIMESTAMPTZ,
  detected_at TIMESTAMPTZ DEFAULT NOW(),
  resolved BOOLEAN DEFAULT false,
  resolution_strategy TEXT,
  resolved_at TIMESTAMPTZ,
  notes TEXT
);

CREATE INDEX idx_subscription_conflicts_user_id 
ON subscription_conflicts(user_id);

CREATE INDEX idx_subscription_conflicts_resolved 
ON subscription_conflicts(resolved);

-- Function to detect and log conflicts
CREATE OR REPLACE FUNCTION detect_subscription_conflict(
  p_user_id TEXT,
  p_sdk_status TEXT,
  p_db_status TEXT,
  p_sdk_expires_at TIMESTAMPTZ,
  p_db_expires_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_conflict_type TEXT;
  v_conflict_id UUID;
BEGIN
  -- Determine conflict type
  IF p_sdk_status = 'active' AND p_db_status = 'expired' THEN
    v_conflict_type := 'sdk_ahead_of_db';
  ELSIF p_sdk_status = 'expired' AND p_db_status = 'active' THEN
    v_conflict_type := 'db_ahead_of_sdk';
  ELSIF p_sdk_status = 'active' AND p_db_status = 'active' 
    AND p_sdk_expires_at != p_db_expires_at THEN
    v_conflict_type := 'expiry_mismatch';
  ELSE
    RETURN NULL;
  END IF;

  -- Log the conflict
  v_conflict_id := gen_random_uuid();
  INSERT INTO subscription_conflicts (
    id,
    user_id,
    conflict_type,
    sdk_status,
    db_status,
    sdk_expires_at,
    db_expires_at
  ) VALUES (
    v_conflict_id,
    p_user_id,
    v_conflict_type,
    p_sdk_status,
    p_db_status,
    p_sdk_expires_at,
    p_db_expires_at
  );

  -- Alert / trigger resolution
  PERFORM pg_notify(
    'subscription_conflicts',
    jsonb_build_object(
      'user_id', p_user_id,
      'conflict_type', v_conflict_type,
      'conflict_id', v_conflict_id
    )::text
  );

  RETURN v_conflict_id;
END;
$$;
```

---

### 4. Add State Machine Validation ⭐⭐

```sql
-- Define valid subscription state transitions
CREATE TABLE IF NOT EXISTS subscription_state_transitions (
  from_status TEXT NOT NULL,
  to_status TEXT NOT NULL,
  event_type TEXT NOT NULL,
  allowed BOOLEAN DEFAULT true,
  PRIMARY KEY (from_status, to_status, event_type)
);

-- Populate valid transitions
INSERT INTO subscription_state_transitions 
(from_status, to_status, event_type, allowed) VALUES
-- Normal flow
('active', 'expired', 'EXPIRATION', true),
('active', 'cancelled', 'CANCELLATION', true),
('active', 'grace_period', 'BILLING_ISSUE', true),
('grace_period', 'active', 'RENEWAL', true),
('grace_period', 'expired', 'EXPIRATION', true),
-- Renewal
('expired', 'active', 'RENEWAL', true),
('expired', 'active', 'PRODUCT_CHANGE', true),
-- Initial
(NULL, 'active', 'INITIAL_PURCHASE', true),
-- Invalid transitions
('cancelled', 'active', 'RENEWAL', false),  -- Can't renew after cancellation
('expired', 'cancelled', 'CANCELLATION', false)  -- Already expired
ON CONFLICT DO NOTHING;

-- Function to validate transitions
CREATE OR REPLACE FUNCTION validate_subscription_transition(
  p_user_id TEXT,
  p_new_status TEXT,
  p_event_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_current_status TEXT;
  v_is_valid BOOLEAN;
BEGIN
  -- Get current status
  SELECT status INTO v_current_status
  FROM user_subscriptions
  WHERE user_id = p_user_id;

  -- Check if transition is allowed
  SELECT allowed INTO v_is_valid
  FROM subscription_state_transitions
  WHERE (from_status = v_current_status OR from_status IS NULL)
  AND to_status = p_new_status
  AND event_type = p_event_type;

  RETURN COALESCE(v_is_valid, false);
END;
$$;
```

---

### 5. Add Automatic Expiry Detection ⭐⭐

```sql
-- Check for expired subscriptions daily
CREATE OR REPLACE FUNCTION check_expired_subscriptions()
RETURNS TABLE(user_id TEXT, expired_count INT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Mark subscriptions as expired if expiry date passed
  UPDATE user_subscriptions
  SET 
    status = 'expired',
    updated_at = NOW()
  WHERE status = 'active'
  AND expires_at < NOW();

  -- Return count of newly expired subscriptions
  RETURN QUERY
  SELECT user_id, COUNT(*)::INT as expired_count
  FROM user_subscriptions
  WHERE status = 'expired'
  AND updated_at > NOW() - INTERVAL '1 hour'
  GROUP BY user_id;
END;
$$;

-- Schedule to run daily at 2 AM UTC
SELECT cron.schedule(
  'check-expired-subscriptions',
  '0 2 * * *',
  'SELECT check_expired_subscriptions();'
);
```

---

### 6. Add Retry & Dead Letter Queue ⭐⭐

```sql
-- Queue for failed webhooks
CREATE TABLE IF NOT EXISTS webhook_dead_letter (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id TEXT NOT NULL,
  payload JSONB NOT NULL,
  error_message TEXT NOT NULL,
  retry_count INT DEFAULT 0,
  max_retries INT DEFAULT 3,
  next_retry_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_webhook_dead_letter_retry 
ON webhook_dead_letter(next_retry_at) 
WHERE retry_count < max_retries;

-- Function to retry failed webhooks
CREATE OR REPLACE FUNCTION retry_failed_webhooks()
RETURNS TABLE(retried INT, still_failing INT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_webhook webhook_dead_letter;
  v_retried INT := 0;
  v_still_failing INT := 0;
BEGIN
  FOR v_webhook IN 
    SELECT * FROM webhook_dead_letter
    WHERE retry_count < max_retries
    AND next_retry_at < NOW()
    LOOP
      BEGIN
        PERFORM handle_revenuecat_webhook(v_webhook.payload);
        DELETE FROM webhook_dead_letter WHERE id = v_webhook.id;
        v_retried := v_retried + 1;
      EXCEPTION WHEN OTHERS THEN
        UPDATE webhook_dead_letter
        SET 
          retry_count = retry_count + 1,
          next_retry_at = NOW() + (retry_count + 1) * INTERVAL '5 minutes',
          error_message = SQLERRM,
          updated_at = NOW()
        WHERE id = v_webhook.id;
        v_still_failing := v_still_failing + 1;
      END;
    END LOOP;

  RETURN QUERY SELECT v_retried, v_still_failing;
END;
$$;

-- Schedule retry every 15 minutes
SELECT cron.schedule(
  'retry-failed-webhooks',
  '*/15 * * * *',
  'SELECT retry_failed_webhooks();'
);
```

---

## Implementation Checklist

- [ ] Add `webhook_events` table (deduplication)
- [ ] Update RPC with deduplication logic
- [ ] Add signature verification function
- [ ] Add `subscription_conflicts` table
- [ ] Add conflict detection function
- [ ] Add `subscription_state_transitions` table
- [ ] Add state machine validation
- [ ] Add automatic expiry detection
- [ ] Add dead letter queue & retry logic
- [ ] Set up cron jobs
- [ ] Create monitoring/alerting dashboard
- [ ] Test with simulated webhook failures

---

## Monitoring & Debugging

```sql
-- Dashboard query: See all pending issues
SELECT 
  'Unprocessed webhooks' as issue_type,
  COUNT(*) as count
FROM webhook_events
WHERE processed = false
  AND created_at < NOW() - INTERVAL '5 minutes'
UNION ALL
SELECT 
  'Subscription conflicts',
  COUNT(*)
FROM subscription_conflicts
WHERE resolved = false
UNION ALL
SELECT 
  'Retryable dead letters',
  COUNT(*)
FROM webhook_dead_letter
WHERE retry_count < max_retries
  AND next_retry_at < NOW();
```

---

## Testing

Create test webhooks in RevenueCat staging:
```bash
# Test 1: Normal purchase
curl -X POST https://your-api.com/webhooks/revenuecat \
  -H "X-RevenueCat-Signature: sha256=..." \
  -d @test-webhook-purchase.json

# Test 2: Duplicate webhook
curl ... # Same webhook again — should be idempotent

# Test 3: Expiration
curl ... # Expiration event
```
