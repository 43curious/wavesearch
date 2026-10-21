.PHONY: core macos build check check-core check-macos check-macos-headless check-macos-runtime _check-macos-runtime check-linux check-format check-scripts check-toolchain clean distclean

PROJECT := macos/WaveSearch/wavesearch.xcodeproj
SCHEME := WaveSearch
DERIVED_DATA := .DerivedData
ZIG ?= zig
HOST_OS := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

core:
ifeq ($(HOST_OS),Darwin)
	ZIG="$(ZIG)" bash ./build.sh
else
	cd core && $(ZIG) build lib -Doptimize=safe
endif

macos: core
	WS_SKIP_CORE_BUILD=1 xcodebuild -quiet \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=$(HOST_ARCH)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
		build

ifeq ($(HOST_OS),Darwin)
build: macos
else
build: core
endif

# The same entry point checks the portable core on Linux and the complete app
# on macOS. Desktop appearance checks require a logged-in macOS session.
check: check-core
ifeq ($(HOST_OS),Darwin)
	$(MAKE) check-macos
else
	@echo "PASS: portable core checks (the SwiftUI app requires macOS)"
endif

check-toolchain:
	@expected=$$(cat .zig-version); actual=$$($(ZIG) version); \
		if [ "$$actual" != "$$expected" ]; then \
			echo "Expected Zig $$expected; found $$actual. Set ZIG to the pinned compiler." >&2; exit 1; \
		fi

check-format: check-toolchain
	cd core && $(ZIG) fmt --check build.zig src

check-scripts:
	@for script in build.sh scripts/*.sh; do bash -n "$$script" || exit; done

check-core: check-format check-scripts
	cd core && $(ZIG) build test -Doptimize=safe --summary all
	cd core && $(ZIG) build lib -Doptimize=safe

# Hosted CI can run these compiled checks without a logged-in desktop. The app
# build refreshes the XCFramework used by the scripts before they link it.
check-macos-headless: macos
	$(MAKE) _check-macos-runtime
	@echo "PASS: macOS build and headless checks"

# Runnable when Xcode project initialization is unavailable. This verifies all
# Swift sources and native checks, but does not validate an Xcode app bundle.
check-macos-runtime: core
	$(MAKE) _check-macos-runtime

_check-macos-runtime:
	bash scripts/test-swift-build.sh
	bash scripts/test-localization.sh
	bash scripts/test-refinement-policy.sh
	bash scripts/test-clap-installer.sh
	bash scripts/test-library-watching.sh
	bash scripts/test-app-lifecycle.sh
	@echo "PASS: Swift compilation and macOS runtime checks"

check-macos: check-macos-headless
	bash scripts/test-window-chrome.sh
	bash scripts/test-settings-appearance.sh
	@echo "PASS: macOS build and app checks"

# Cross-compile the library and all core check executables without running them.
# Run check-core on Linux to execute the native tests there.
check-linux: check-format check-scripts
	cd core && $(ZIG) build lib check-compile -Doptimize=safe -Dtarget=x86_64-linux-gnu --prefix zig-out/linux-x86_64

clean:
	rm -rf "$(DERIVED_DATA)/Build"
	rm -rf .zig-cache
	cd core && rm -rf .zig-cache zig-out
	rm -rf core/WaveSearchKit.xcframework
	rm -rf macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework

distclean: clean
	rm -rf "$(DERIVED_DATA)"
