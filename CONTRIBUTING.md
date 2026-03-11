# Contributing

## Development Setup

1. Open `ZeroLose/ZeroLose.xcodeproj` in Xcode.
2. Set your API keys from the app Settings screen after launch.
3. Run build and tests before submitting changes.

## Build and Test

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' build
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test
```

## Pull Request Rules

- Keep changes focused and small.
- Include tests for behavior changes.
- Do not introduce hardcoded secrets.
- Update docs when behavior changes.

## Code Quality

- Prefer `async/await` over callback-style APIs.
- Keep UI state updates on `@MainActor`.
- Avoid force unwraps outside test code.
