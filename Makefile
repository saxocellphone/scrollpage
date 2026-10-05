APP_NAME    := Scrollpage
APP         := build/$(APP_NAME).app
BINARY      := .build/release/$(APP_NAME)
INSTALL_DIR ?= /Applications
# macOS ties Accessibility and Camera approvals to the signature. "local" signs
# with a self-signed identity kept in this clone's .git (scripts/local-signing.sh),
# so approvals survive rebuilds. "-" signs ad hoc: every build needs approving
# again. A Developer ID also works:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= $(if $(GITHUB_ACTIONS),-,local)
DIAGNOSE_SECONDS     ?= 15

ifeq ($(SIGN_IDENTITY),-)
SIGN = codesign --force --sign -
else ifeq ($(SIGN_IDENTITY),local)
SIGN = scripts/local-signing.sh
else
SIGN = codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --timestamp
endif

.PHONY: build app run test install diagnose check-permissions test-scroll clean

build: app

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP)/Contents/Info.plist
	$(SIGN) --entitlements Scrollpage.entitlements $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

test:
	swift test

install: app
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

diagnose: app
	$(APP)/Contents/MacOS/$(APP_NAME) --diagnose $(DIAGNOSE_SECONDS)

# Launched through LaunchServices so TCC checks the app itself, not this shell.
check-permissions:
	@out=$$(mktemp); open -W -n --stdout "$$out" --stderr "$$out" $(APP) --args --check-permissions; cat "$$out"; rm -f "$$out"

# Posts a synthetic fling at the pointer from the app itself.
test-scroll:
	@out=$$(mktemp); open -W -n --stdout "$$out" --stderr "$$out" $(APP) --args --test-scroll $(VY); cat "$$out"; rm -f "$$out"

clean:
	rm -rf build .build
