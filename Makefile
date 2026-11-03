DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Token Tracker.app

.PHONY: project test live-test build run install clean

project:
	xcodegen generate

test:
	cd Packages/UsageKit && swift test

# Hits the real endpoints with this Mac's Claude Code and Codex logins.
live-test:
	cd Packages/UsageKit && LIVE=1 swift test --filter LiveTests

build: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Debug \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build -quiet

run: build
	-pkill -x "Token Tracker"
	sleep 1
	open "$(APP)"

# Release build copied to /Applications, so it survives rebuilds and shows up in Spotlight.
install: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build -quiet
	-pkill -x "Token Tracker"
	rm -rf "/Applications/Token Tracker.app"
	ditto "$(DERIVED)/Build/Products/Release/Token Tracker.app" "/Applications/Token Tracker.app"
	sleep 1
	open "/Applications/Token Tracker.app"

clean:
	rm -rf $(DERIVED) TokenTracker.xcodeproj
