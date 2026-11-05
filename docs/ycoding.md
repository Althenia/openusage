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

Keep YCoding installed and configure the connections there. OpenUsage discovers those connections at
startup through the local `ycoding` CLI. Restart OpenUsage after adding, removing, reconnecting, or
renaming a YCoding connection.

This integration reads connection metadata and usage reports through YCoding's existing API. It does
not copy YCoding tokens or keys, export credentials, create accounts, or change authentication settings.
YCoding remains responsible for provider requests and renewing its own login. Calling its CLI may
start YCoding's managed local service, and fetching usage may cause YCoding to contact providers.
Its public quota-list API reads configured connections together, so refreshing one profile can
refresh YCoding's quota cache for other connections too. Turning off a card hides it in OpenUsage;
it does not disconnect that account in YCoding.

## Profiles And Usage

A card belongs to one YCoding connection, identified by its stable connection ID and exact profile.
Changing the active connection does not move usage between cards. Two profiles are kept separate even
when they belong to the same provider account.

Quota meters show only allowances that YCoding can report for that profile. Availability varies by
provider, connection, and plan. A missing allowance is not treated as zero remaining usage.
OpenAI's five-hour and seven-day windows determine the Session and Weekly labels. A weekly allowance
can be YCoding's primary window; it remains Weekly and retains its reported reset time.
If the window duration is missing or unfamiliar, OpenUsage leaves the quota unavailable instead of
guessing its period from the primary/secondary position.

Known OpenAI and Anthropic API-key connections show recorded activity without subscription meters.
YCoding does not provide their remaining credit balances. Missing balances are not shown as zero, and
usage values do not establish credit consumption. Reporting authorization errors remain visible.
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

Today, Yesterday, and Last 30 Days preserve prices already recorded by YCoding. If a model group has
no prices, OpenUsage can use its shared model-pricing catalog when the model and token categories are
reliable. Those dollars are labeled **estimated usage value**, not billed charges, a credit balance,
or subscription consumption. This applies to every supported provider, including Muse and Antigravity.
Each incomplete dollar subtotal is marked **partial** on its own period row.

Unknown models or rates, missing cache telemetry, and cache writes with an unknown lifetime remain
unpriced. A model group containing both priced and unpriced requests also remains partly unpriced:
the public report does not separate their token counts. OpenUsage keeps the recorded subtotal instead
of estimating the same tokens again. Long-context estimates require enough information to identify
the applicable rate tier. Incomplete totals retain a warning; missing prices never become zero.

All YCoding usage-value rows remain separate from **Total Spend**. They do not establish billed charges,
and native account-wide histories can include the same requests. The connection metadata cannot prove
whether those sources overlap.

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
- **YCoding could not be reached:** check that the local `ycoding` CLI works and try again. OpenUsage
  reports a failure rather than displaying invented usage.
- **YCoding returned incompatible usage:** update YCoding so its connection and usage interfaces
  match the current reporting contract.

YCoding profiles are separate from **Settings → Profiles**, which configures additional Claude and
Codex folders on disk.
