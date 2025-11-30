# Build stage
FROM rust:1.91.1-bookworm AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the project files
COPY Cargo.toml Cargo.lock ./
COPY build.rs ./
COPY src ./src
COPY abi ./abi

# Create a dummy deployments.json for build
RUN echo '{"account": "0x0000000000000000000000000000000000000000", "orderbook": "0x0000000000000000000000000000000000000000", "sequencer": "0x0000000000000000000000000000000000000000", "pairId": "0x0000000000000000000000000000000000000000000000000000000000000000"}' > ../deployments.json

# Build the release binary
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from builder
COPY --from=builder /app/target/release/matcher /app/matcher

# Copy default config
COPY config.toml.example /app/config.toml.example

# Create volume mount points
VOLUME ["/app/config"]

# Expose API port
EXPOSE 8080

# Set environment variables
ENV RUST_LOG=info

# Default command
ENTRYPOINT ["/app/matcher"]
CMD ["-c", "/app/config/config.toml"]
