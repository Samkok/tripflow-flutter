# VoyZa — Supabase Auth email templates

Paste each file's contents into **Supabase Dashboard → Authentication → Email Templates**, matching the tab below. Set the **Subject** field to the subject shown.

| Dashboard tab | Subject line | File |
|---|---|---|
| Confirm signup | Confirm your email to finish setting up VoyZa | `supabase/email-templates/confirm_signup.html` |
| Reset password | Reset your VoyZa password | `supabase/email-templates/reset_password.html` |
| Magic Link | Your VoyZa sign-in link | `supabase/email-templates/magic_link.html` |
| Invite user | You're invited to join VoyZa | `supabase/email-templates/invite_user.html` |
| Change Email Address | Confirm your new VoyZa email address | `supabase/email-templates/change_email.html` |
| Reauthentication | Your VoyZa verification code | `supabase/email-templates/reauthentication.html` |

Variables used are Supabase GoTrue tokens ({{ .ConfirmationURL }}, {{ .Token }}, {{ .Email }}, {{ .NewEmail }}) — leave them exactly as-is.
Prerequisite: enable Custom SMTP (Resend) first, or these still send via the default service and may land in spam.
