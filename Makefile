.PHONY: native test ios-project ios-build linux
native:
	cargo build --locked --release

test:
	cargo test --locked

linux:
	./scripts/build-linux-musl.sh

# 开发机使用已安装 xcodegen；目标机器运行二进制不需要它。
ios-project:
	cd ios && xcodegen generate

ios-build: ios-project
	xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO build
