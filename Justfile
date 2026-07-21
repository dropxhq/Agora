default:
    @just --list

# 启动 A2A mock server，供 Agora 客户端调试
a2a-demo:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}/python"
    echo "→ 同步依赖..."
    uv sync
    echo ""
    echo "Agora A2A Demo Server 启动中"
    echo "  URL:  http://localhost:8000"
    echo "  在 Agora 客户端 Backend 中填入上述地址即可调试"
    echo "  按 Ctrl+C 停止"
    echo ""
    exec uv run python -m a2a_demo

# 用 cargo-swift 将 agora-a2a 打成本地 Swift Package（macOS + iOS）
# 需要: cargo install cargo-swift@0.11.1
a2a-swift:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}/rust/agora-a2a"
    if ! command -v cargo-swift >/dev/null 2>&1; then
      echo "→ 安装 cargo-swift@0.11.1..."
      cargo install cargo-swift@0.11.1 -f
    fi

    # Align C deps (aws-lc etc.) with the Xcode app deployment target so ld
    # does not warn: object built for newer macOS than being linked.
    # Match agora/agora.xcodeproj MACOSX_DEPLOYMENT_TARGET / IPHONEOS_DEPLOYMENT_TARGET.
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
    export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
    # Keep Apple Clang on the host macOS SDK while compiling darwin targets;
    # cargo-swift still selects the correct SDK per-target internally.
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

    echo "→ 构建 AgoraA2A Swift Package..."
    echo "  MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
    echo "  IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET"
    cargo swift package \
      -n AgoraA2A \
      -p macos \
      -p ios \
      -y \
      --release \
      --swift-tools-version 6.0

    # UniFFI 0.31 bindings still trip Swift 6 strict concurrency on callback vtables.
    python3 - <<'PY'
    from pathlib import Path
    root = Path("AgoraA2A")
    pkg = root / "Package.swift"
    # Force Swift 5 language mode + macOS/iOS system frameworks needed by reqwest.
    pkg.write_text("""// swift-tools-version:6.0
    // The swift-tools-version declares the minimum version of Swift required to build this package.
    // Swift Package: AgoraA2A

    import PackageDescription;

    let package = Package(
        name: "AgoraA2A",
        platforms: [
            .macOS(.v10_15), .iOS(.v13)
        ],
        products: [
            .library(
                name: "AgoraA2A",
                targets: ["AgoraA2A"]
            )
        ],
        dependencies: [ ],
        targets: [
            .binaryTarget(name: "AgoraA2AFFI", path: "./AgoraA2AFFI.xcframework"),
            .target(
                name: "AgoraA2A",
                dependencies: [
                    .target(name: "AgoraA2AFFI")
                ],
                linkerSettings: [
                    .linkedFramework("SystemConfiguration"),
                    .linkedFramework("Security"),
                    .linkedFramework("CoreFoundation"),
                ]
            ),
        ],
        // UniFFI 0.31 generated sources are not fully Swift-6-Sendable clean yet.
        swiftLanguageModes: [.v5]
    )
    """)

    swift = root / "Sources" / "AgoraA2A" / "AgoraA2A.swift"
    src = swift.read_text()
    old = "    static let vtablePtr: UnsafePointer<UniffiVTableCallbackInterfaceStreamObserver> = {"
    new = "    nonisolated(unsafe) static let vtablePtr: UnsafePointer<UniffiVTableCallbackInterfaceStreamObserver> = {"
    if old in src:
        swift.write_text(src.replace(old, new, 1))
    print("→ patched Package.swift + UniFFI Swift concurrency")
    PY

    echo ""
    echo "完成: {{justfile_directory()}}/rust/agora-a2a/AgoraA2A"
    echo "在 Xcode 中以 local package 依赖该目录即可。"
