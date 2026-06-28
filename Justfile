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
