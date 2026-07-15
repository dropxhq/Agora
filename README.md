# Agora

A native macOS & iOS client for the A2A protocol — connect, manage, and chat with any Agent2Agent-compatible AI agent.

## Native A2A stack

Protocol transport lives in Rust (`a2a-client` via UniFFI) and is consumed by the SwiftUI app as a local Swift Package.

```sh
# Build the AgoraA2A Swift Package (requires cargo-swift@0.11.1)
just a2a-swift

# Optional: local mock agent for UI debugging
just a2a-demo   # http://localhost:8000
```

Xcode already references `rust/agora-a2a/AgoraA2A` as a local package. Run `just a2a-swift` once after clone (or after Rust changes) before building the app.
