# Stack: Go

Modern defaults (2025–2026): **go modules** + **golangci-lint** (meta-linter) + **gofumpt** (stricter gofmt) + standard layout (`cmd/`, `internal/`, `pkg/` only if genuinely reusable). Go 1.24+ `go get -tool` for tool pinning.

## Tooling decisions

| Concern | Default | Notes |
|---|---|---|
| Modules | `go mod init <module-path>` | module path e.g. `github.com/<owner>/<name>` |
| Lint | **golangci-lint** (`.golangci.yml`) | aggregates 50+ linters; used by Kubernetes/Prometheus |
| Format | **gofumpt** | superset of gofmt; wire into CI + editor |
| Layout | `cmd/<binary>/` thin mains, `internal/` private, `pkg/` external-only | avoid premature `pkg/` |
| Test | `go test` + table tests | `-race -cover` in CI |

## Files to generate

### `go.mod`
```
module github.com/<owner>/<project-name>

go 1.24
```

### Source + test
For a **library**, `greet.go` at module root; for an **app/CLI**, put `main` under `cmd/<name>/`.

`greet.go`:
```go
// Package <name> provides greetings.
package <name>

import "fmt"

// Greet returns a friendly greeting.
func Greet(name string) string {
	return fmt.Sprintf("Hello, %s!", name)
}
```
`greet_test.go`:
```go
package <name>

import "testing"

func TestGreet(t *testing.T) {
	got := Greet("world")
	want := "Hello, world!"
	if got != want {
		t.Errorf("Greet() = %q, want %q", got, want)
	}
}
```
For a CLI, also `cmd/<name>/main.go` calling the package.

### `.golangci.yml`
```yaml
version: "2"
linters:
  enable:
    - errcheck
    - govet
    - staticcheck
    - unused
    - ineffassign
    - gocritic
    - revive
formatters:
  enable:
    - gofumpt
    - goimports
```

### `Makefile`
```makefile
.PHONY: build test lint fmt
build:
	go build ./...
test:
	go test -race -cover ./...
lint:
	golangci-lint run
fmt:
	gofumpt -w .
```

### `mise.toml`
```toml
[tools]
go = "1.24"
golangci-lint = "latest"
```

## Extend `.gitignore`
```
/bin/
*.exe
*.test
*.out
vendor/
```

## Finalize commands
```bash
go mod tidy
go test -race -cover ./...
golangci-lint run
```
Periodic dead-code sweep (not a CI gate): `go run golang.org/x/tools/cmd/deadcode@latest ./...` (staticcheck `U1000` in golangci-lint also flags unused unexported code). `go mod tidy` is the dependency audit. See [maintenance-and-hygiene.md](maintenance-and-hygiene.md).
