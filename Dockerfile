# One image: the Dart server plus the built console it serves.
#   docker build -t openbird .
FROM oven/bun:1.3 AS console
WORKDIR /console
COPY dashboard/package.json dashboard/bun.lock ./
RUN bun install --frozen-lockfile
COPY protocol/openapi.yaml /protocol/openapi.yaml
COPY dashboard/ ./
RUN bun run gen:api && bun run build

FROM dart:3.10 AS server
WORKDIR /app
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get
COPY server/ ./
RUN dart compile exe bin/server.dart -o /app/server && dart compile exe bin/admin.dart -o /app/admin

# The dart image's /runtime holds the minimal libraries and CA certificates
# an AOT executable needs.
FROM scratch
COPY --from=server /runtime/ /
COPY --from=server /app/server /app/admin /app/
COPY server/migrations /app/migrations
COPY --from=console /console/dist /app/console
WORKDIR /app
ENV PORT=8080 MIGRATIONS_DIR=/app/migrations DASHBOARD_DIR=/app/console \
    STORAGE_DIR=/data/storage STAGING_DIR=/data/staging
EXPOSE 8080
CMD ["/app/server"]
