ICLOUD ?= NO
DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Token Tracker.app

.PHONY: project test live-test build run ios clean

project:
	xcodegen generate

test:
	cd Packages/UsageKit && swift test

# Hits the real endpoints with this Mac's Claude Code and Codex logins.
live-test:
	cd Packages/UsageKit && LIVE=1 swift test --filter LiveTests

build: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Debug \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates TT_ICLOUD=$(ICLOUD) build -quiet

run: build
	-pkill -x "Token Tracker"
	open "$(APP)"

# Needs a paid Apple Developer team (iCloud + push).
ios: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerIOS -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'generic/platform=iOS' -allowProvisioningUpdates build -quiet

clean:
	rm -rf $(DERIVED) TokenTracker.xcodeproj
