#!/usr/bin/env bash
set -euo pipefail

FOCUSED_FILTER='YCodingQuotaMappingTests|YCodingAuthenticationMappingTests|YCodingConnectionClientTests|YCodingConnectionProviderTests|YCodingUsagePricingTests|TotalSpendAggregatorTests|LayoutStoreTests'

classify() {
  swift_relevant=false
  selector_tests=false
  eligible=true
  seen=false
  while IFS= read -r path || [ -n "$path" ]; do
    [ -z "$path" ] && continue
    seen=true
    case "$path" in
      .github/workflows/ci.yml|script/ci/select-tests.sh|script/ci/select-tests.test.sh)
        selector_tests=true
        ;;
      Sources/OpenUsage/Providers/YCoding/*|\
      Sources/OpenUsage/Stores/DefaultLayout.swift|\
      Sources/OpenUsage/Views/TotalSpendCard.swift|\
      Tests/OpenUsageTests/YCodingQuotaMappingTests.swift|\
      Tests/OpenUsageTests/YCodingAuthenticationMappingTests.swift|\
      Tests/OpenUsageTests/YCodingConnectionClientTests.swift|\
      Tests/OpenUsageTests/YCodingConnectionProviderTests.swift|\
      Tests/OpenUsageTests/YCodingUsagePricingTests.swift|\
      Tests/OpenUsageTests/TotalSpendAggregatorTests.swift|\
      Tests/OpenUsageTests/LayoutStoreTests.swift)
        swift_relevant=true
        ;;
      docs/ycoding.md|Tests/OpenUsageTests/YCodingInstalledIntegrationTests.swift)
        ;;
      *)
        eligible=false
        ;;
    esac
  done

  if [ "$seen" != true ]; then
    echo "select-tests: empty changed-file list is indeterminate" >&2
    return 2
  fi

  if [ "$eligible" != true ]; then
    printf 'mode=full\nfilter=\nrun_selector_tests=%s\n' "$selector_tests"
  elif [ "$swift_relevant" = true ]; then
    printf 'mode=focused\nfilter=%s\nrun_selector_tests=%s\n' "$FOCUSED_FILTER" "$selector_tests"
  else
    printf 'mode=skip-swift\nfilter=\nrun_selector_tests=%s\n' "$selector_tests"
  fi
}

case "${1:-}" in
  files)
    classify
    ;;
  range)
    base="${2:-}"
    head="${3:-}"
    zero='0000000000000000000000000000000000000000'
    if [ -z "$base" ] || [ "$base" = "$zero" ] || [ -z "$head" ] || [ "$head" = "$zero" ]; then
      echo "select-tests: missing or zero base/head revision" >&2
      exit 2
    fi
    git cat-file -e "$base^{commit}" 2>/dev/null || {
      echo "select-tests: base revision is unavailable" >&2
      exit 2
    }
    git cat-file -e "$head^{commit}" 2>/dev/null || {
      echo "select-tests: head revision is unavailable" >&2
      exit 2
    }
    merge_base="$(git merge-base "$base" "$head" 2>/dev/null)" || {
      echo "select-tests: no merge base for the revision range" >&2
      exit 2
    }
    if [ -z "$merge_base" ]; then
      echo "select-tests: no merge base for the revision range" >&2
      exit 2
    fi
    git diff --name-only "$merge_base" "$head" | classify
    ;;
  *)
    echo "usage: select-tests.sh files | range <base> <head>" >&2
    exit 2
    ;;
esac
