# 1. ビルド用コンテナ
FROM rust:1.88 as builder

WORKDIR /app
# 依存だけ先にコピーしてビルドするとキャッシュが効く
COPY Cargo.toml Cargo.lock ./
COPY src ./src

RUN cargo build --release

# 2. 実行用コンテナ（小さくて軽い）
FROM debian:bookworm-slim

# 必要最低限のライブラリだけ追加
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/target/release/backend /app/backend

ENV RUST_LOG=info
EXPOSE 3000

CMD ["./backend"]
