#!/usr/bin/env bash
# Stop hook — runs after every Claude Code turn. A red build blocks finishing.
set -e

echo "Running tsc..."
npx tsc --noEmit

echo "Running jest..."
npx jest --silent

echo "Verify OK."
