# Runs the platform-independent LincolnCore test suite on Linux. The macOS app
# target (Lincoln.xcodeproj) can only be built and tested with Xcode; see
# Scripts/test.sh for the full local run.
#
#   docker build -t lincoln-core-tests .
#   (or: docker compose run tests / docker-compose run tests)

FROM swift:6.0-noble

WORKDIR /workspace/LincolnCore
COPY LincolnCore/Package.swift ./
COPY LincolnCore/Sources ./Sources
COPY LincolnCore/Tests ./Tests

RUN swift build --build-tests
RUN swift test --skip-build
