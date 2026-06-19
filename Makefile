APP_NAME := QuickMarkShot
BUILD_DIR := build
SWIFT_BUILD_DIR := .build
MODULE_CACHE := $(SWIFT_BUILD_DIR)/ModuleCache
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(BUILD_DIR)/$(APP_NAME)
CONTENTS := $(APP_DIR)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clean run restart app

all: app

app:
	$(LSREGISTER) -u "$(APP_DIR)" 2>/dev/null || true
	$(LSREGISTER) -u "/Users/shallwez/Documents/截图 app/build/$(APP_NAME).app" 2>/dev/null || true
	rm -rf "$(APP_DIR)" "$(BIN)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp Info.plist "$(CONTENTS)/Info.plist"
	printf "APPL????" > "$(CONTENTS)/PkgInfo"
	swiftc -swift-version 5 -O \
		-module-cache-path "$(MODULE_CACHE)" \
		-framework Cocoa \
		-framework Carbon \
		-framework CoreGraphics \
		-framework ScreenCaptureKit \
		Sources/*.swift \
		-o "$(MACOS)/$(APP_NAME)"
	swiftc -swift-version 5 -O \
		-module-cache-path "$(MODULE_CACHE)" \
		-framework Cocoa \
		-framework Carbon \
		-framework CoreGraphics \
		-framework ScreenCaptureKit \
		Sources/*.swift \
		-o "$(BIN)"
	xattr -cr "$(APP_DIR)"
	codesign --force --deep --sign - \
		--requirements '=designated => identifier "local.quickmarkshot.app"' \
		"$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	xattr -cr "$(APP_DIR)"
	touch "$(APP_DIR)"
	$(LSREGISTER) -f "$$(pwd)/$(APP_DIR)"

run: app
	"$(BIN)"

restart: app
	pkill -x "$(APP_NAME)" 2>/dev/null || true
	kill -9 $$(pgrep -x "$(APP_NAME)" 2>/dev/null) 2>/dev/null || true
	sleep 1
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)" "$(SWIFT_BUILD_DIR)"
