#!/usr/bin/env bash
# run-app-tests.sh - Run all application-specific tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

echo "======================================"
echo "Application-Specific Tests"
echo "======================================"
echo

# Track results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Run each app test
for test_script in apps/test-*.sh; do
    if [[ -f "$test_script" ]]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        app_name=$(basename "$test_script" .sh | sed 's/test-//')

        info "Running $app_name tests..."
        echo

        if bash "$test_script"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
            success "$app_name tests passed"
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            error "$app_name tests failed"
        fi
        echo
    fi
done

# Summary
echo "======================================"
echo "Application Tests Summary"
echo "======================================"
echo "Total apps tested: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All application tests passed!${NC}"
fi
echo
