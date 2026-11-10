#!/usr/bin/env bash
set -u

cd "$(dirname "$0")/../.." || exit 1
SELECTOR="script/ci/select-tests.sh"
FILTER='YCodingQuotaMappingTests|YCodingAuthenticationMappingTests|YCodingConnectionClientTests|YCodingConnectionProviderTests|YCodingUsagePricingTests|TotalSpendAggregatorTests|LayoutStoreTests'
failures=0

check() {
  name="$1" expected="$2" input="$3"
  actual="$(printf '%s\n' "$input" | bash "$SELECTOR" files 2>&1)"
  status=$?
  if [ $status -ne 0 ] || [ "$actual" != "$expected" ]; then
    echo "FAIL $name (status $status)"
    echo "expected:"
    printf '%s\n' "$expected"
    echo "actual:"
    printf '%s\n' "$actual"
    failures=$((failures + 1))
  else
    echo "PASS $name"
  fi
}

check_fails() {
  name="$1" input="$2"
  printf '%s\n' "$input" | bash "$SELECTOR" files >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "FAIL $name (expected nonzero exit)"
    failures=$((failures + 1))
  else
    echo "PASS $name"
  fi
}

focused="mode=focused
filter=$FILTER
run_selector_tests=false"

check "ycoding source only" "$focused" "Sources/OpenUsage/Providers/YCoding/YCodingConnectionMapper.swift"

skip_swift="mode=skip-swift
filter=
run_selector_tests=false"

check "installed integration test file never selected" "$skip_swift" "Tests/OpenUsageTests/YCodingInstalledIntegrationTests.swift"

outgoing='Sources/OpenUsage/Providers/YCoding/YCodingConnectionClient.swift
Sources/OpenUsage/Providers/YCoding/YCodingConnectionMapper.swift
Sources/OpenUsage/Providers/YCoding/YCodingConnectionModels.swift
Sources/OpenUsage/Providers/YCoding/YCodingConnectionProvider.swift
Sources/OpenUsage/Providers/YCoding/YCodingPaths.swift
Sources/OpenUsage/Providers/YCoding/YCodingProviderAssembly.swift
Sources/OpenUsage/Providers/YCoding/YCodingUsagePricing.swift
Sources/OpenUsage/Stores/DefaultLayout.swift
Sources/OpenUsage/Views/TotalSpendCard.swift
Tests/OpenUsageTests/YCodingAuthenticationMappingTests.swift
Tests/OpenUsageTests/YCodingConnectionClientTests.swift
Tests/OpenUsageTests/YCodingConnectionProviderTests.swift
Tests/OpenUsageTests/YCodingInstalledIntegrationTests.swift
Tests/OpenUsageTests/YCodingQuotaMappingTests.swift
Tests/OpenUsageTests/YCodingUsagePricingTests.swift
docs/ycoding.md
.github/workflows/ci.yml
script/ci/select-tests.sh
script/ci/select-tests.test.sh'
check "outgoing ycoding push with ci change" "mode=focused
filter=$FILTER
run_selector_tests=true" "$outgoing"

check "ci only" "mode=skip-swift
filter=
run_selector_tests=true" ".github/workflows/ci.yml"

check "docs only" "mode=skip-swift
filter=
run_selector_tests=false" "docs/ycoding.md"

check "unrelated source" "mode=full
filter=
run_selector_tests=false" "Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift"

check "mixed ycoding and unrelated" "mode=full
filter=
run_selector_tests=false" "Sources/OpenUsage/Providers/YCoding/YCodingConnectionMapper.swift
Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift"

check "unrelated test file" "mode=full
filter=
run_selector_tests=false" "Tests/OpenUsageTests/ClaudeProviderTests.swift"

check "unselected ycoding test keeps full coverage" "mode=full
filter=
run_selector_tests=false" "Tests/OpenUsageTests/YCodingCredentialReaderTests.swift"

check_fails "empty file list is indeterminate" ""

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" config user.email test@example.invalid
git -C "$tmp" config user.name Test
mkdir -p "$tmp/Sources/OpenUsage/Providers/YCoding" "$tmp/script/ci"
cp "$SELECTOR" "$tmp/script/ci/select-tests.sh" || exit 1
printf 'one\n' > "$tmp/Sources/OpenUsage/Providers/YCoding/A.swift"
git -C "$tmp" add -A
git -C "$tmp" commit -qm base
base="$(git -C "$tmp" rev-parse HEAD)"
printf 'two\n' >> "$tmp/Sources/OpenUsage/Providers/YCoding/A.swift"
git -C "$tmp" add -A
git -C "$tmp" commit -qm change
head="$(git -C "$tmp" rev-parse HEAD)"

actual="$(cd "$tmp" && bash script/ci/select-tests.sh range "$base" "$head" 2>&1)"
if [ $? -ne 0 ] || [ "$actual" != "$focused" ]; then
  echo "FAIL range ycoding change"
  printf '%s\n' "$actual"
  failures=$((failures + 1))
else
  echo "PASS range ycoding change"
fi

(cd "$tmp" && bash script/ci/select-tests.sh range 0000000000000000000000000000000000000000 "$head") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL range zero base fails closed"
  failures=$((failures + 1))
else
  echo "PASS range zero base fails closed"
fi

(cd "$tmp" && bash script/ci/select-tests.sh range deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$head") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL range missing base fails closed"
  failures=$((failures + 1))
else
  echo "PASS range missing base fails closed"
fi

if [ $failures -ne 0 ]; then
  echo "$failures selector test(s) failed"
  exit 1
fi
echo "All selector tests passed"
