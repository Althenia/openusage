# Muse

Tracks subscription usage for Meta Muse Code, the coding agent distributed by Meta.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Percent used in the current 5-hour window, with the provider's reset time |
| Weekly | Percent used in the weekly window, with the Monday 00:00 UTC reset time |

The provider's `tier` value is an opaque ID, not a plan name, so OpenUsage does not display a plan badge. Percentages are shown as received and may exceed 100%. Reset times are converted from Unix seconds to dates. The weekly duration is treated as seven days.

Both meters start enabled, Always Visible, and pinned to the menu bar. Each refresh makes one small streamed Muse model request to retrieve usage; it is a model call, not a separate free quota endpoint.

## Credentials

Nothing to paste or save in OpenUsage. Sign in using `muse login`. OpenUsage reads `auth.json` at `MUSE_AUTH_PATH`, else `$XDG_CONFIG_HOME/muse/auth.json`, else `~/.config/muse/auth.json`. It requires the `providers.meta` entry to identify OAuth credentials stored in macOS Keychain, then reads the Meta keychain item scoped to service `ai.meta.dev.credentials` and account `meta`. OpenUsage reads the API key from that item and never writes the auth file or Keychain.

macOS asks before OpenUsage can read the Muse Keychain item. Automatic refreshes never show that popup: until access is granted, Muse shows “Muse login found. Refresh once and choose Always Allow to connect it.” Refresh manually and choose **Always Allow**. OpenUsage keeps the key in memory while it runs and reads the Keychain again only when Muse rejects the key or after you log out. If Muse saves a new login, macOS may ask once more on the next manual refresh. Detecting Muse on first launch only checks that the Keychain item exists; it never reads the secret. A plain YCoding `META_API_KEY` credential is not used because that path does not return subscription usage events.

## How it works

OpenUsage sends one streamed `POST <api_base_url>/responses` request using the stored key as `Authorization: Bearer …` and `x-client-id: tbh:exec`. It requests a small `muse-spark-1.2` completion with `max_output_tokens: 16`, then reads the complete server-sent event stream and maps its `response.subscription_usage` event. The event contains the session and weekly `used_percent` values and reset times; the 5-hour window duration arrives in minutes. No plan name or used/limit counts are returned by this event.

## Troubleshooting

- **“Run muse login and try again.”** Muse credentials are missing or the request was rejected with HTTP 401/403. Sign in with Muse again.
- **“Your Muse subscription is inactive.”** The local Muse auth file marks the subscription inactive. Restore an active subscription in Muse.
- **“Muse subscription usage is unavailable.”** The response did not contain a valid subscription-usage event. OpenUsage reports the failure instead of showing stale or fabricated meters.
