.PHONY: install build test generate

# Builds a signed Release copy and installs it to /Applications.
install:
	./scripts/install.sh

# Debug build, matching what Xcode's ⌘R produces, without touching Xcode's own DerivedData.
build:
	xcodebuild -project SnapShelf.xcodeproj -scheme SnapShelf -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath .build/DerivedData build

test:
	xcodebuild -project SnapShelf.xcodeproj -scheme SnapShelf \
		-destination 'platform=macOS' -derivedDataPath .build/DerivedData test

# Regenerates SnapShelf.xcodeproj from project.yml.
generate:
	xcodegen generate
