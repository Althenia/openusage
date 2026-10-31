# Local Storage

OpenUsage keeps app-owned settings, account and profile metadata, cached snapshots, parsed usage
history, pricing downloads, and telemetry bookkeeping in SQLite. The release app uses
`~/.local/share/openusage/openusage.db` by default. An absolute `XDG_DATA_HOME` in the process
environment changes the directory to `$XDG_DATA_HOME/openusage`.

The app and command use the same location resolver. A Finder-launched app does not inherit shell-only
exports. Give both processes the same `XDG_DATA_HOME` if they should share a database. Relative,
empty, and `~`-prefixed values are ignored. Location resolution never reads the persisted shell
environment snapshot.

Development builds and other bundle IDs use `openusage-<SHA256 of bundle ID>.db` in the same directory.
An unbundled app uses the development bundle ID. The command uses the containing app's bundle ID,
or the release ID when it is not inside an app. `OPENUSAGE_DEFAULTS_SUITE` selects a different bundle
namespace for the command, including the legacy domain to import.

## First Launch After Upgrade

The first launch imports a fixed list of app-owned settings from the bundle's preferences domain,
the four telemetry values from its separate suite, and the old pricing, Cursor history, and parsed-log
caches under `~/Library/Application Support/OpenUsage`. Unknown preferences, framework settings,
and unrelated files are not imported.

The app reads its own preferences through the current app's defaults. The command selects the
containing app's preferences domain explicitly, so both import the same app-owned settings.

The import and its completion marker commit in one transaction. Existing SQLite rows take precedence.
A failed import rolls back and blocks startup rather than starting with empty settings. A later launch
can retry after the underlying problem is resolved. After success, the app never imports those sources
again and writes only to SQLite.

The original preferences and cache files remain untouched. Older builds can still read those retained
copies, but changes made by an older build do not appear in SQLite, and newer changes do not flow back
to the old copies. Do not use old and new builds as synchronized writers.

## Versions and Failures

SQLite's `user_version` describes the database structure. The separate settings-content version tracks
layout and provider-setting transformations. Settings upgrades run against SQLite, not the originals.
Fresh-install detection reads SQLite so later launches do not repeat onboarding.

The app and command use transactions and a bounded wait for competing writers. A corrupt, foreign,
unsupported newer, or inaccessible database is not deleted or replaced automatically. Startup failures
show an alert in the app; the command reports an error and exits with code `4`. Setting read or write
failures are logged and reported in an app alert.

SQLite uses its rollback journal to recover interrupted writes on the next open. Preference reads and
cache work use separate connections to the same file. Readers can continue during a pending write;
commits and competing writers wait only for the configured lock timeout.

The storage directory is owner-only (`0700`); the database and SQLite sidecars are owner-readable and
writable only (`0600`). The database is not encrypted. It contains local usage and account metadata,
including profile paths and account identity stamps, but no imported API keys or credential payloads.
The app refuses a symlinked storage directory or database. Keep the resolved storage directory owned
by your macOS account rather than pointing it at another location with a symlink.

## Unchanged Storage

- Provider credentials, user-supplied API keys, and the Antigravity token cache keep their existing
  protected files or Keychain items.
- The iCloud device identity remains Keychain-first. Its local fallback and the sync-enabled setting
  move to SQLite; the history JSON schemas, iCloud container, and file coordination remain unchanged.
- Peer history remains in memory and is not copied into the local snapshot cache.
- Sparkle, KeyboardShortcuts, PostHog, login-item state, logs, and the process lock retain their own
  storage. User-authored proxy configuration stays in place.
- Telemetry uses a separate SQLite namespace. Settings reset still preserves the analytics choice,
  anonymous install ID, profiles, cached usage, credentials, and iCloud device identity.
