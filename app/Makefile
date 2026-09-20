# sigstop, build with Command Line Tools only. No Xcode required.
.DEFAULT_GOAL := help
.PHONY: help build bundle run test doctor fmt lint clean dev-cert verify

APP     := sigstop
CONFIG  ?= release
BUNDLE  := dist/$(APP).app

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile (CONFIG=debug|release)
	swift build -c $(CONFIG)

bundle: ## Assemble and sign $(BUNDLE)
	@CONFIG=$(CONFIG) ./Scripts/bundle.sh

run: bundle ## Build, bundle, and launch
	@pkill -x $(APP) 2>/dev/null || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP) >/dev/null || break; sleep 0.2; done
	@open $(BUNDLE)
	@echo "launched, look in the menu bar"

# swift-testing ships INSIDE Command Line Tools but is not on any default search
# path, and its Foundation cross-import overlay has a broken module symlink there.
# These four flags are the whole reason `swift test` works without Xcode:
#   -F / -Xlinker -F   find Testing.framework at compile and link time
#   -rpath             let the built test bundle dlopen it (DYLD_* is stripped by SIP)
#   -disable-cross-import-overlay-search   skip the broken _Testing_Foundation overlay
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F -Xswiftc $(TESTING_FW) \
              -Xlinker -F -Xlinker $(TESTING_FW) \
              -Xlinker -rpath -Xlinker $(TESTING_FW) \
              -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlay-search

test: ## Run the Core test suite (no GUI session, no Xcode needed)
	@swift test $(TEST_FLAGS)

doctor: ## Print exactly what the app can observe right now
	@swift run -c $(CONFIG) $(APP) --doctor

fmt: ## Format sources
	@swift-format format -i -r Sources Tests && echo "formatted"

lint: ## Lint sources
	@swift-format lint -r Sources Tests

verify: bundle ## Prove the privacy claims against the built binary
	@BUNDLE=$(BUNDLE) ./Scripts/verify.sh

dev-cert: ## One-time: create a stable self-signed identity so TCC grants survive rebuilds
	@if security find-identity -v -p codesigning | grep -q "sigstop-dev"; then \
		echo "identity 'sigstop-dev' already exists"; \
	else \
		echo "macOS keys the Accessibility grant to the binary's cdhash."; \
		echo "swift build ad-hoc-signs, so the cdhash changes every build and the"; \
		echo "grant silently disappears. Create a stable identity ONCE:"; \
		echo ""; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Keychain Access > Certificate Assistant > Create a Certificate…"; \
		echo "  3. Name: sigstop-dev   Identity Type: Self Signed Root"; \
		echo "     Certificate Type: Code Signing"; \
		echo "  4. Then build with:  SIGN_IDENTITY=sigstop-dev make bundle"; \
		echo ""; \
		echo "(This needs Keychain UI, so it is not scripted, a half-working"; \
		echo " automation here would be worse than a clear instruction.)"; \
	fi

clean: ## Remove build artifacts
	rm -rf .build dist
