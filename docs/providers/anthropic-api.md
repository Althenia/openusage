# Anthropic API

Anthropic API tracks organization reporting from the Claude Console. It is separate from the Claude
provider, which tracks a Claude subscription and local Claude Code activity.

Anthropic connections configured in YCoding appear separately through the [YCoding integration](../ycoding.md).
Existing account and ordinary API-key connections keep their own profiles. Their recorded YCoding
usage does not require or imply access to the organization reports described on this page.

## Metrics

Both rows cover the current UTC calendar month through the last completed UTC hour:

- **Usage** — Messages API tokens across the organization. Anthropic's `total_tokens` includes uncached
  input, output, cache reads, and both cache-creation durations once. Message Batches, Claude Code,
  Console, and other product surfaces are not included in this row.
- **Cost** — organization-wide reported USD API cost, including non-token costs and other product
  surfaces. This uses Anthropic's actual `amount` after discounts and before credits, not list-price
  estimates. Fractional cents are converted to dollars without rounding individual rows.

Cost is not an invoice total or a remaining balance. Separately billed Priority Tier commitment fees
are absent from Anthropic's report; tokens covered by the commitment have zero reported token cost.

Anthropic typically refreshes this data within four hours and can take up to 24 hours. The provider
shows each report's freshness watermark when the requested hours extend beyond it. Current-month
figures are not final: Anthropic can reconcile them until about seven days after the month ends.
During the first UTC hour of a month, no completed hourly reporting window exists yet.

The descriptors are `anthropicAPI.usage` then `anthropicAPI.cost`, titled **Usage** and **Cost**.
Enabled, Always Visible, and menu-bar pin defaults are defined by the shared layout configuration.

## Credentials And Access

The provider reads only an already configured key, in this order:

1. `~/.config/openusage/anthropic-api.json`
2. `ANTHROPIC_ADMIN_API_KEY`

The config file follows the shared API-key store formats: JSON with `apiKey`, `api_key`, or `key`, or
a plain-text key. Settings manages the same file through `APIKeyManaging`. Saved keys override the
environment; removing the saved key restores an environment key if one exists. Shared file persistence
uses atomic replacement and owner-only `0600` permissions.

Use an existing Claude Console organization Admin API key. Anthropic permits organization admins to
provision Admin API keys; owners and primary owners have admin permissions. These keys have broad
organization privileges, not a reporting-only scope. Individual accounts do not have Admin API access.

Anthropic also documents organization-scoped personal/service-account credentials and `org:admin`
OAuth tokens for its Admin APIs, and `read:analytics` keys for enabled Claude Enterprise analytics.
This integration does not discover or obtain those credentials, implement OAuth, or read ordinary
`ANTHROPIC_API_KEY` inference credentials. Workspace-scoped inference keys do not provide organization
admin reporting. Cloud-platform authentication and endpoints are outside this provider.

Local detection only checks the dedicated file and environment source. It does not validate access
over the network. The provider does not query account details, list members or keys, create keys,
change permissions, or access a credential database or keychain.

## Requests

The provider makes read-only requests to `https://api.anthropic.com`:

- `GET /v1/organizations/analytics/usage`, with `products[]=messages_api`
- `GET /v1/organizations/analytics/cost`, without product or identity filters

Both requests send `x-api-key`, `anthropic-version: 2023-06-01`, and
`anthropic-beta: analytics-usage-cost-2026-08-24`. They specify inclusive `starting_at`, exclusive
`ending_at`, `time_bucket_width=1h`, and `limit=1000`. No grouping is requested, so hourly organization
totals do not overlap across identities or workspaces.

Pagination preserves all query parameters and follows `has_more` and the opaque `next_page` cursor.
An expired cursor (HTTP 410) restarts that report once from its first page, discarding earlier subtotals.
Every page must have the same `data_refreshed_at` watermark. Duplicate buckets, invalid ranges,
malformed cursors, and malformed numeric fields fail the report rather than yielding a partial total.

The older `/usage_report/messages` and `/cost_report` endpoints remain supported by Anthropic but are
legacy and are not used here. The analytics endpoints are currently beta.

## Errors And Partial Reports

- **No key** — neither dedicated source has a usable key.
- **Invalid key** — HTTP 401 rejects the configured key.
- **Permission denied** — HTTP 403 rejects reporting access. This is distinct from a missing key.
- **Unsupported reporting** — HTTP 404, 405, or 501 indicates the reporting capability is unavailable.
- **Missing data** — the export watermark is null or does not cover this month's reporting window.
- **Invalid data** — required fields, numeric values, bucket bounds, or pagination are malformed.
- **Unsupported currency** — cost currency is not USD. No conversion or silent omission is performed.
- **Network or HTTP failure** — the provider reports the failure without substituting zero.

A well-formed empty report with a covering export watermark can represent zero. An absent export,
missing `data`, or malformed report cannot.

Usage and Cost are fetched independently. If one complete report succeeds, its row remains available
and a warning names the failed row. A report that fails on a later page contributes no subtotal. If
both fail, the provider returns an error snapshot. Freshness and cost-scope notices remain visible
with successful figures so they are not presented as complete invoice totals.

## Official References

Verified against Anthropic's public documentation on October 31, 2026:

- [Usage and Cost Analytics API](https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api)
  — product filtering, totals, Priority Tier exclusions, UTC bucket rounding, freshness, and reconciliation.
- [Usage endpoint reference](https://platform.claude.com/docs/en/api/beta/organization/analytics/usage/list)
  — token totals, date limits, pagination, and export watermarks.
- [Cost endpoint reference](https://platform.claude.com/docs/en/api/beta/organization/analytics/cost/list)
  — actual versus list cost, fractional-cent USD amounts, and pagination.
- [Admin API authentication and roles](https://platform.claude.com/docs/en/manage-claude/admin-api)
  — organization access, credential types, and admin/owner roles.
- [Admin API keys](https://platform.claude.com/docs/en/manage-claude/admin-api-keys)
  — key privileges, creation roles, and Enterprise analytics scopes.
- [Legacy Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)
  — supported legacy endpoints and their limitations.
