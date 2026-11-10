# YCoding

OpenUsage can show the provider connections already configured in YCoding. Each connection keeps its
own profile instead of being merged into whichever account is currently active.

Supported providers are OpenAI, Anthropic, Antigravity, Muse, and Cursor. OpenAI and Anthropic account
connections and ordinary API-key connections are both included. When YCoding supplies the connection's
non-secret `kind`, the card identifies it as **Account** or **API Key**. Older YCoding versions omit this
field; those cards say **Type Unknown**. OpenUsage never guesses from a profile name, an error, or a quota.
YCoding must expose Muse as its own integration; a Meta organization API connection is not treated
as a Muse subscription.

## Connecting

Keep YCoding installed and configure the connections there. OpenUsage auto-discovers the running local
YCoding background service (`service.json` in the YCoding state directory) and queries its HTTP API directly,
falling back to the `ycoding` CLI when the service is not running. Restart OpenUsage after adding, removing,
reconnecting, or renaming a YCoding connection.

This integration reads connection metadata and usage reports through YCoding's existing API. It does
not copy YCoding tokens or keys, export credentials, create accounts, or change authentication settings.
YCoding remains responsible for provider requests and renewing its own login. Calling its CLI or API may
start YCoding's managed local service, and fetching usage may cause YCoding to contact providers.
Its public quota-list API reads configured connections together, so refreshing one profile can
refresh YCoding's quota cache for other connections too. Turning off a card hides it in OpenUsage;
it does not disconnect that account in YCoding.

## Profiles And Usage

A card belongs to one YCoding connection, identified by its stable connection ID and exact profile.
Changing the active connection does not move usage between cards. Two profiles are kept separate even
when they belong to the same provider account. Each YCoding profile card includes a **Usage Trend**
sparkline and model-level hover breakdowns on **Today**, **Yesterday**, and **Last 30 Days**.

Quota meters show only allowances that YCoding can report for that profile. Availability varies by
provider, connection, and plan. A missing allowance is not treated as zero remaining usage.
OpenAI's five-hour and seven-day windows determine the Session and Weekly labels. A weekly allowance
can be YCoding's primary window; it remains Weekly and retains its reported reset time.
If the window duration is missing or unfamiliar, OpenUsage leaves the quota unavailable instead of
guessing its period from the primary/secondary position.

OpenAI account cards also show **Extra Usage** (Codex credits, e.g. "$374.80 · 9.4K credits") and
**Rate Limit Resets** ("2 available") when YCoding reports them, and Anthropic account cards show
**Extra Usage** spent against its monthly limit. A reported zero is shown as zero. A balance YCoding
does not report, or reports as unlimited, leaves the row empty instead of showing a number.

Known OpenAI and Anthropic API-key connections show recorded activity without subscription meters.
OpenAI API-key cards show **API Credit Balance**, and Anthropic account cards show **Prepaid Balance**,
when YCoding can read a USD balance. The OpenAI figure is aggregate API grants and can include different
grant types; its undocumented endpoint may reject project keys. Anthropic's balance is separate from
its monthly extra-usage limit and spend. Missing balances are not shown as zero, and usage values do not
establish credit consumption. Balance rows are enabled below the caret and are not pinned by default.
Reporting authorization and refresh failures remain visible alongside recorded activity. An OpenAI
credit balance can also be shown with a warning when organization usage is unavailable.
Native Claude and Codex cards keep their own login status and source, separate from YCoding profiles.

An explicit refresh can ask YCoding to refresh its Muse account probe. Automatic refreshes do not
force that probe; they use the account-bound usage YCoding already has when available. This is
separate from the native Muse provider's manual model request described in the [Muse guide](providers/muse.md).

Recorded usage belongs to a card only when the report explicitly names that provider and profile.
Historical requests marked as using a provider default are excluded: the currently active connection
does not prove which connection handled an older request. Ambiguous or unbound account usage is also
excluded instead of assigned to a profile.

YCoding's historical reports identify activity by provider and profile name, not by the saved
credential ID. Reusing a profile name after reconnecting can include that name's earlier activity.
These figures describe recorded profile activity; they do not establish which account owned every
past request.

## Recorded And Estimated Usage Value

Today, Yesterday, Last 30 Days, and the Usage Trend keep prices YCoding recorded for fully priced
model groups. When any request in a model group is unpriced, OpenUsage prices that group's input,
output, cache-read, and cache-write tokens through its shared model-pricing catalog instead, replacing
the partial recorded subtotal so no tokens count twice. YCoding reports cache writes without a five-minute/one-hour breakdown,
so OpenUsage prices them at the five-minute write rate.
Those dollars are labeled **estimated usage value**, not billed charges, a credit balance, or
subscription consumption. This applies to every supported provider, including Muse and Antigravity.

When some requests in a group did not report cache reads, YCoding counts their cached input as
ordinary input. OpenUsage prices it at the full input rate, so that estimate is an upper bound; it is
exact only when those requests had no cache hits.

On the Usage Trend, a day where a model mixed priced and unpriced requests shows OpenUsage's
estimate for all of that model's tokens in place of YCoding's partial subtotal; other models keep
their recorded prices. Days that include models without a known price (for example
`muse-wonder-full-1.0-contributor` or `muse-spark-1.3-contributor`) understate that day. The trend
has no per-day partial marker.
Models the catalog does not know stay unpriced; missing prices never become zero. A period that still
contains unpriced usage is marked **partial** on its own row, without a card warning. Long-context
estimates require enough information to identify the applicable rate tier.

Muse cards whose account has no profile-bound quota show Session and Weekly as **No data** next to
the recorded usage, without a warning.

YCoding profile usage-value rows participate in the **Total Spend** ring chart (Cost, Cost/MTok, and Tokens).

An ordinary OpenAI or Anthropic API key can contribute recorded YCoding usage without granting
organization reporting access. This does not turn that key into an Admin API key. The separate
[OpenAI API](providers/openai-api.md) and [Anthropic API](providers/anthropic-api.md) providers continue
to require their dedicated organization Admin credentials.

## Troubleshooting

- **A connection is missing:** verify it exists in YCoding, then restart OpenUsage.
- **A profile needs a login:** reconnect that profile in YCoding, then restart OpenUsage.
- **Quotas are unavailable:** the provider or connection may not expose an allowance to YCoding.
  Recorded local usage and an account's subscription quota are different measurements.
- **Older activity is missing:** activity without an explicit profile cannot be safely assigned to
  the current connection.
- **YCoding could not be reached:** check that the local YCoding background service or `ycoding` CLI
  works and try again. OpenUsage reports a failure rather than displaying invented usage.
- **YCoding returned incompatible usage:** update YCoding so its connection and usage interfaces
  match the current reporting contract.

YCoding profiles are separate from **Settings → Profiles**, which configures additional Claude and
Codex folders on disk.
