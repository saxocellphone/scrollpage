APP_NAME    := Scrollpage
APP         := build/$(APP_NAME).app
BINARY      := .build/release/$(APP_NAME)
INSTALL_DIR ?= /Applications
# "-" signs ad hoc. Pass a Developer ID to keep privacy grants across rebuilds:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= -
DIAGNOSE_SECONDS     ?= 15

ifeq ($(SIGN_IDENTITY),-)
SIGN_FLAGS := --sign -
else
SIGN_FLAGS := --sign "$(SIGN_IDENTITY)" --options runtime --timestamp
endif

.PHONY: build app run test install diagnose clean

build: app

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force $(SIGN_FLAGS) --entitlements Scrollpage.entitlements $(APP)
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

clean:
	rm -rf build .build
