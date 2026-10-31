# OpenAI API

Tracks the current UTC calendar month's organization API activity and reported USD costs. This is
separate from the Codex provider and from ChatGPT or Codex subscription quotas.

## Metrics

| Metric | Meaning |
|---|---|
| Completions Tokens | Organization completion input tokens plus output tokens, including text, audio, and image tokens |
| Cost | Actual organization-wide USD cost returned by OpenAI's Costs API, not a local pricing estimate |

Both rows cover month-to-date, starting at 00:00 UTC on the first day of the month. Cached and
cache-write input tokens are already included in `input_tokens` and are counted once. The completion
token row is not an all-services token total: it does not add embeddings, moderation, images, audio
services, storage, or tool usage reported through other usage endpoints. Completion tokens can include
Scale Tier activity.

Costs cover the organization without project, model, API key, or line-item filters. They can therefore
include charges outside the completion-token row, including organization-level Scale Tier charges.
The two metrics do not imply a common per-token price. Neither row represents remaining credits, a
budget limit, or a ChatGPT/Codex subscription allowance. OpenAI may update its reports after activity
occurs; the rows show the reports available at refresh time.

## Credentials and Access

An existing **API Platform organization Admin API key** with permission to read organization usage
and costs is required. Only API Platform organization owners can create organization Admin keys.
Dashboard visibility, project ownership, a normal inference API key, and a ChatGPT workspace Admin key
are not substitutes. OpenUsage does not create keys or change organization permissions.

Credentials come from these sources, in order:

1. `~/.config/openusage/openai-api.json`, managed through **Settings → API Keys**. The file accepts
   `apiKey`, `api_key`, or `key` JSON fields, or a plain-text key. App writes replace it atomically with
   owner-only file permissions.
2. `OPENAI_ADMIN_KEY`, the environment variable used in OpenAI's official Admin API examples.

A saved key overrides the environment value. Removing the saved key restores the environment value,
if present. `OPENAI_API_KEY` is deliberately ignored. No credential database, keychain, CLI session,
or other provider's configuration is searched.

## Requests and Validation

OpenUsage sends authenticated, read-only requests to:

- `GET https://api.openai.com/v1/organization/usage/completions`
- `GET https://api.openai.com/v1/organization/costs`

Each request specifies the UTC month start as inclusive `start_time`, refresh time in Unix seconds as
exclusive `end_time`, `bucket_width=1d`, and `limit=31`. Both reports follow `has_more` and `next_page`
until completion. Daily response buckets may extend to the end of the current UTC day; the request's
exclusive end time still bounds the report. Buckets outside that daily window or overlapping buckets
are rejected.

A complete, valid empty report displays zero. Missing fields, malformed results, invalid token counts,
incomplete or repeated pagination, transport errors, and forbidden requests never become zero. Both
reports must succeed before either metric is published. Cost results must contain a finite numeric
amount and `usd` currency; signed adjustments are preserved rather than clamped.

## Error States

- **No Admin key:** neither dedicated credential source contains a usable key.
- **Rejected key (401):** OpenAI did not accept the supplied credential.
- **Permission denied (403):** the Admin key cannot read the organization reports. Contact the API
  Platform organization owner; OpenUsage does not broaden access.
- **Reporting unavailable (404/405):** the organization report endpoint is unavailable.
- **Unsupported currency:** costs were not reported in USD; no conversion or estimate is substituted.
- **Incomplete or malformed report:** required data or pagination is unusable; no partial total is shown.
- **Network, rate limit, or server error:** the refresh failed and exposes an error instead of a number.

The shared key store treats an unreadable or unusable saved key as absent and then checks the dedicated
environment variable. A local credential-file read failure is not currently distinguished from a
missing saved key.

## Official Sources

Verified October 31, 2026:

- [Organization Usage and Costs API](https://platform.openai.com/docs/api-reference/usage): endpoints,
  query ranges, pagination, completion token fields, result objects, and cost currency.
- [Admin APIs guide](https://developers.openai.com/api/docs/guides/admin-apis): Admin credentials and
  `OPENAI_ADMIN_KEY`.
- [Admin and Audit Logs API](https://help.openai.com/en/articles/9687866-admin-and-audit-logs-api-for-the-api-platform):
  organization-owner requirements and distinction from ChatGPT workspace Admin keys.
- [Reviewing API Usage and Costs](https://help.openai.com/en/articles/10478918-reviewing-api-usage-and-costs):
  UTC reporting, dashboard permissions, and organization-level Scale Tier costs.
