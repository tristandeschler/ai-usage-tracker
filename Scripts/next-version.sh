#!/bin/bash
# Prints the version the next release should use: one patch above the latest v* tag, unless
# MARKETING_VERSION in project.yml is higher (that's how to ask for a minor or major bump).
set -euo pipefail
cd "$(dirname "$0")/.."

latest=$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')
project=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)

if [ -z "$latest" ]; then
    echo "$project"
    exit 0
fi

IFS=. read -r major minor patch <<< "$latest"
next="$major.$minor.$((patch + 1))"

# Pick whichever is higher.
highest=$(printf '%s\n%s\n' "$next" "$project" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
echo "$highest"
