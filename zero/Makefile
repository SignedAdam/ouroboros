SHELL := /bin/zsh
BUILD := .build/release
APP   := build/Ouroboros Zero.app
BIN   := $(HOME)/.local/bin

.PHONY: all build test install app run stop clean

all: build

build:
	swift build -c release --product ouro
	swift build -c release --product ourod
	swift build -c release --product ouroboros-zero

test:
	swift test

## ouro and ourod must land in the same directory: the daemon resolves the shim
## as its sibling. `rm` before `cp`, never `cp -f`: overwriting a code-signed
## Mach-O in place invalidates its signature, and macOS then SIGKILLs it on exec.
install: build app
	mkdir -p "$(BIN)"
	rm -f "$(BIN)/ouro" "$(BIN)/ourod"
	cp "$(BUILD)/ouro"  "$(BIN)/ouro"
	cp "$(BUILD)/ourod" "$(BIN)/ourod"
	rm -rf "$(HOME)/.ouroboros/tools"
	mkdir -p "$(HOME)/.ouroboros/tools"
	cp tools/* "$(HOME)/.ouroboros/tools/"
	find "$(HOME)/.ouroboros/tools" -type f ! -name '*.md' -exec chmod +x {} +
	@echo ""
	@echo "  installed: $(BIN)/ouro  $(BIN)/ourod"
	@echo "  app:       $(APP)"
	@echo ""
	@echo "  next:"
	@echo "    ouro setup                       # find and adopt your repos"
	@echo "    ouro i \"something is broken\"     # file one"
	@echo "    open \"$(APP)\"                    # menu bar + ⌥Space"
	@echo ""

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BUILD)/ouroboros-zero" "$(APP)/Contents/MacOS/ouroboros-zero"
	cp "$(BUILD)/ourod"          "$(APP)/Contents/MacOS/ourod"
	cp "$(BUILD)/ouro"           "$(APP)/Contents/MacOS/ouro"
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>Ouroboros Zero</string>' \
	  '  <key>CFBundleDisplayName</key><string>Ouroboros Zero</string>' \
	  '  <key>CFBundleIdentifier</key><string>com.albastov.ouroboros.zero</string>' \
	  '  <key>CFBundleExecutable</key><string>ouroboros-zero</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
	  '  <key>CFBundleVersion</key><string>1</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '</dict></plist>' > "$(APP)/Contents/Info.plist"
	@echo "built $(APP)"

run: app
	open "$(APP)"

stop:
	-ouro daemon stop 2>/dev/null || true
	-pkill -f ouroboros-zero 2>/dev/null || true

clean:
	rm -rf .build build
