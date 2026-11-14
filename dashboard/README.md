# openBird console

The web console, built with React, Vite, TypeScript, Tailwind CSS, TanStack
Query and Recharts. In production the server serves `dist/` (`DASHBOARD_DIR`).

```sh
bun install
bun run dev        # http://localhost:5173, proxies the API to tool/dev.sh on :8080
bun run build      # dist/
bun run typecheck
bun run gen:api    # regenerate src/api/schema.ts from ../protocol/openapi.yaml
```

`src/api/schema.ts` is generated; don't edit it. Protocol calls go to
`/api/v1` (the same routes the Shorebird CLI uses). Console-only calls go to
`/console/v1`.
