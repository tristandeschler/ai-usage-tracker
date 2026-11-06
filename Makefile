DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Token Tracker.app

.PHONY: project test build run install release clean

project:
	xcodegen generate

test:
	cd Packages/UsageKit && swift test

build: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Debug \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet

run: build
	-pkill -x "Token Tracker"
	sleep 1
	open "$(APP)"

# Release build copied to /Applications, so it survives rebuilds and shows up in Spotlight.
install: project
	xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
	-pkill -x "Token Tracker"
	rm -rf "/Applications/Token Tracker.app"
	ditto "$(DERIVED)/Build/Products/Release/Token Tracker.app" "/Applications/Token Tracker.app"
	sleep 1
	open "/Applications/Token Tracker.app"

# Developer ID-signed, notarized zip in build/release (needs a paid team signed in to Xcode).
release:
	Scripts/release.sh

clean:
	rm -rf $(DERIVED) TokenTracker.xcodeproj
