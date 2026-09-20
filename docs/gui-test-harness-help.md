# GUI test harness

Run `make test-gui` or `swift scripts/run-gui-tests.swift [xcodebuild options]`.
Use `--help` for this text or `--version` for the harness version.

The harness runs serial macOS XCUITests and forwards their output and exit status.
Additional arguments, such as `-derivedDataPath` and `-only-testing:...`, go directly
to xcodebuild.

On this host XCTest's native menu click can dismiss Edit without dispatching
Paste Image. The affected test opens Edit and checks Paste Image's availability,
then requests that exact menu activation from the host through a test-log record.
The host uses System Events against the test application's process ID; XCTest
still verifies that the image imports with an empty prior lock chain. The
completion record lives in a temporary directory owned and removed by the test.
No production test hook or permission setting is changed.

The host must already have macOS permission to control System Events. The
sandboxed XCUITest runner cannot invoke System Events directly. Keep the parent
harness running for the suite so native menu actions use the same host context.
Run this test through this harness; direct xcodebuild execution cannot service
its native-menu request and fails with an explicit timeout.
