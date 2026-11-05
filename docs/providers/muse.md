# Muse

Tracks subscription usage for Meta Muse Code, the coding agent distributed by Meta.

Muse connections configured in YCoding appear as separate [YCoding profile cards](../ycoding.md).
Their usage comes from YCoding's reporting interface. The native Muse login and streamed request
described below are independent of those profiles, and an ordinary API key does not imply a
subscription allowance. YCoding profile activity includes recorded or estimated model usage value
when reliable pricing is available; it is not a Muse subscription charge. Missing rates or token
categories remain explicitly incomplete. See the [YCoding guide](../ycoding.md).

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Percent used in the current 5-hour window, with the provider's reset time |
| Weekly | Percent used in the weekly window, with the Monday 00:00 UTC reset time |

The provider's `tier` value is an opaque ID, not a plan name, so OpenUsage does not display a plan badge. Percentages are shown as received and may exceed 100%. Reset times are converted from Unix seconds to dates. The weekly duration is treated as seven days.

Both meters start enabled, Always Visible, and pinned to the menu bar. An explicit manual refresh
makes one small streamed Muse model request to retrieve usage. This can consume usage or incur a
charge; it is not a separate free quota endpoint. Startup, polling, and displaying the card do not
send that model request.

Until a manual refresh succeeds during the current run, the provider asks you to refresh manually.
After a successful manual refresh, automatic updates reuse that result with a notice that another
manual refresh is needed for current usage. A failed manual refresh clears the retained result.

## Credentials

Nothing to paste or save in OpenUsage. Sign in using `muse login`. OpenUsage reads `auth.json` at `MUSE_AUTH_PATH`, else `$XDG_CONFIG_HOME/muse/auth.json`, else `~/.config/muse/auth.json`. It requires the `providers.meta` entry to identify OAuth credentials stored in macOS Keychain, then reads the Meta keychain item scoped to service `ai.meta.dev.credentials` and account `meta`. OpenUsage reads the API key from that item and never writes the auth file or Keychain.

macOS asks before OpenUsage can read the Muse Keychain item. Automatic refreshes do not read the key
or show that popup. Refresh manually and choose **Always Allow** when macOS asks. OpenUsage keeps the
key in memory while it runs and reads the Keychain again only when Muse rejects the key or after you
log out. If Muse saves a new login, macOS may ask once more on the next manual refresh. Detecting Muse
on first launch only checks that the Keychain item exists; it never reads the secret. This native
provider does not read YCoding credentials. YCoding profiles use the separate reporting integration
described above, which only shows quotas that YCoding can actually supply.

## How it works

On an explicit manual refresh, OpenUsage sends one streamed `POST <api_base_url>/responses` request
using the stored key as `Authorization: Bearer …` and `x-client-id: tbh:exec`. It requests a small
`muse-spark-1.2` completion with `max_output_tokens: 16`, then reads the complete server-sent event
stream and maps its `response.subscription_usage` event. The event contains the session and weekly
`used_percent` values and reset times; the 5-hour window duration arrives in minutes. No plan name or
used/limit counts are returned by this event.

## Troubleshooting

- **“Run muse login and try again.”** Muse credentials are missing or the request was rejected with HTTP 401/403. Sign in with Muse again.
- **“Your Muse subscription is inactive.”** The local Muse auth file marks the subscription inactive. Restore an active subscription in Muse.
- **“Muse subscription usage is unavailable.”** The response did not contain a valid subscription-usage event. OpenUsage reports the failure instead of showing stale or fabricated meters.
- **Manual refresh required:** use an explicit refresh to make the small model request and retrieve
  current subscription usage.
