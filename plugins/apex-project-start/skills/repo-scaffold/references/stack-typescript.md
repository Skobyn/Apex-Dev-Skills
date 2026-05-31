# Stack: TypeScript / JavaScript

Modern defaults (2025–2026): **pnpm** + **strict tsconfig** + **Biome** + **Vitest**. Use ESLint flat config + Prettier instead only if the project needs niche plugins (security/a11y/framework-specific) — note that as an ADR if so.

## Tooling decisions

| Concern | Default | When to deviate |
|---|---|---|
| Package manager | **pnpm** | `bun` if you want runtime+test+bundler in one binary; `npm` only for zero-dep simplicity |
| Lang config | strict `tsconfig.json` | — |
| Lint + format | **Biome** (one binary, one config) | ESLint flat config + Prettier for plugin breadth |
| Test | **Vitest** | `bun test` for pure-unit on Bun |
| Build/framework | library → `tsup`/Vite; app → Vite (SPA) or Next.js (SSR/full-stack) | — |
| Runtime pin | `mise.toml` (node = "lts") or `.nvmrc` | — |

## Files to generate

### `package.json`
```json
{
  "name": "<project-name>",
  "version": "0.1.0",
  "description": "<purpose>",
  "type": "module",
  "license": "<SPDX>",
  "author": "skobyn <skobyn@gmail.com>",
  "packageManager": "pnpm@9",
  "scripts": {
    "build": "tsup src/index.ts --format esm,cjs --dts",
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage",
    "lint": "biome check .",
    "format": "biome format --write .",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@biomejs/biome": "^2.3.0",
    "typescript": "^5.7.0",
    "tsup": "^8.3.0",
    "vitest": "^2.1.0",
    "@vitest/coverage-v8": "^2.1.0"
  }
}
```
For an **app** (Next/Vite) swap build/scripts and deps accordingly; drop `tsup`.

### `tsconfig.json`
Extend a strict base ([`@tsconfig/strictest`](https://github.com/tsconfig/bases)) or inline:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "verbatimModuleSyntax": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src", "tests"]
}
```

### `biome.json`
```json
{
  "$schema": "https://biomejs.dev/schemas/2.3.0/schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "files": { "ignoreUnknown": true },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2 },
  "linter": { "enabled": true, "rules": { "recommended": true } },
  "javascript": { "formatter": { "quoteStyle": "double" } }
}
```

### `vitest.config.ts`
```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      thresholds: { lines: 80, functions: 80, branches: 70, statements: 80 },
    },
  },
});
```

### Source + test
`src/index.ts`:
```ts
export function greet(name: string): string {
  return `Hello, ${name}!`;
}
```
`tests/index.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { greet } from "../src/index.js";

describe("greet", () => {
  it("greets by name", () => {
    expect(greet("world")).toBe("Hello, world!");
  });
});
```

### `mise.toml`
```toml
[tools]
node = "lts"
pnpm = "latest"
```

## Extend `.gitignore`
```
node_modules/
dist/
coverage/
*.tsbuildinfo
.turbo/
.next/
```

## Finalize commands
```bash
pnpm install
pnpm test
pnpm lint
```
