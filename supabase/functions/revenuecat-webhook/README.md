# RevenueCat Webhook Handler

Supabase Edge Function that processes RevenueCat webhook events and updates the `user_subscriptions` table for real-time subscription expiration detection.

## Deployment

### Prerequisites

1. Install Supabase CLI:
```bash
npm install -g supabase
```

2. Link to your project:
```bash
supabase link --project-ref YOUR_PROJECT_REF
```

### Deploy the Function

```bash
# From project root
cd supabase/functions

# Deploy
supabase functions deploy revenuecat-webhook
```

### Configure Secrets

```bash
# Set the webhook authorization key (generate a secure random string)
supabase secrets set REVENUECAT_WEBHOOK_AUTH_KEY=your_secret_key_here

# Verify secrets
supabase secrets list
```

## Configure RevenueCat

1. Go to RevenueCat Dashboard → Project Settings → Integrations → Webhooks
2. Add webhook URL: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/revenuecat-webhook`
3. Set Authorization header: `Bearer your_secret_key_here` (same as above)
4. Select events: **All transaction events** (or select specific ones from the list)
5. Save and test using "Send Test Event"

## Testing

### Local Testing

1. Start Supabase locally:
```bash
supabase start
```

2. In another terminal, expose with ngrok:
```bash
ngrok http 54321
```

3. Configure RevenueCat webhook to use ngrok URL:
```
https://YOUR_NGROK_ID.ngrok.io/functions/v1/revenuecat-webhook
```

### Test with curl

```bash
curl -X POST https://YOUR_PROJECT.supabase.co/functions/v1/revenuecat-webhook \
  -H "Authorization: Bearer YOUR_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "type": "INITIAL_PURCHASE",
      "app_user_id": "YOUR_USER_UUID",
      "entitlement_ids": ["premium"],
      "product_id": "monthly",
      "store": "play_store",
      "expiration_at_ms": 1735689600000,
      "purchased_at_ms": 1704067200000,
      "will_renew": true
    },
    "api_version": "1.0"
  }'
```

### Verify in Database

```sql
SELECT * FROM user_subscriptions WHERE user_id = 'YOUR_USER_UUID';
```

## Events Handled

- `INITIAL_PURCHASE` - First subscription
- `RENEWAL` - Subscription renewed
- `CANCELLATION` - User cancelled (still active until expiration)
- `UNCANCELLATION` - User reactivated
- `EXPIRATION` - Subscription expired
- `BILLING_ISSUE` - Payment failed (grace period)
- `PRODUCT_CHANGE` - Upgraded/downgraded
- `TRANSFER` - Subscription transferred
- `NON_RENEWING_PURCHASE` - One-time purchase

## Monitoring

### View Logs

```bash
# Real-time logs
supabase functions logs revenuecat-webhook --follow

# Filter by error level
supabase functions logs revenuecat-webhook --level error
```

### Check Webhook Delivery in RevenueCat

1. Go to RevenueCat Dashboard → Webhooks
2. View delivery history
3. Check for failed deliveries
4. Review response codes

## Troubleshooting

### Webhook Returns 401 Unauthorized

- Verify `REVENUECAT_WEBHOOK_AUTH_KEY` is set correctly
- Check Authorization header in RevenueCat webhook configuration
- Ensure header format is `Bearer YOUR_KEY` (not just `YOUR_KEY`)

### Webhook Returns 400 Bad Request

- Check that `app_user_id` in RevenueCat matches Supabase user UUID format
- Verify payload structure matches expected format
- Check function logs for details

### Webhook Returns 500 Internal Server Error

- Check function logs: `supabase functions logs revenuecat-webhook`
- Verify `upsert_subscription_status` function exists in database
- Check service role permissions

### Database Not Updating

- Verify migration 009 was run successfully
- Check RLS policies allow service role to INSERT/UPDATE
- Verify realtime is enabled on `user_subscriptions` table

## Security Notes

- The webhook handler uses `SECURITY DEFINER` function to bypass RLS
- Only service role can call `upsert_subscription_status`
- Users can only SELECT their own subscription data
- Authorization header validation prevents unauthorized access
- UUID validation prevents injection attacks
