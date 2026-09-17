# Menso

Menso is a native macOS desktop assistant: talk, review a small Mac action, approve it, and see the verified result.

The app has one resizable window with live captions, a start/end voice control, action approvals, and results. Say "Open Brave" or focus a field and ask Menso to type. The Mac resolves installed apps and focused targets without a preparation form. Each execution still requires local approval. Supported actions are opening an app, focusing a known window, inserting text without submitting, and setting a focused control.

Voice uses OpenAI `gpt-live-1` with client delegation. TypeSafe `jev-latest` selects one candidate from a request-scoped native action catalog. There is no Agno agent in the active action path. The signed Mac owns microphone access, exact targets/text, policy, approvals, execution, and verification. Provider keys stay on the backend. AgentOS remains only as the existing authenticated HTTP/database host.

## How it works

```text
Your voice → GPT-Live → TypeSafe selects a native action candidate
                                  ↓
                     Mac approval → execution → verification
                                  ↓
                          Result back to GPT-Live
```

The Mac supplies known apps and the focused window/control as request-scoped metadata. TypeSafe returns a candidate ID or abstains; it does not generate executable code or arbitrary tool arguments. Only the Mac can create an approval card and execute an action. Saying “please approve” is not an approval request unless that native card exists.

## Current scope

| Supported in source | Not supported |
| --- | --- |
| Live voice conversation and captions | Screen reading or screenshots |
| Open or bring an installed app forward | Arbitrary clicks, shell commands, or browser automation |
| Focus a known window | Multi-step autonomous tasks |
| Insert exact dictated text without submitting | Generating drafts or composing text for insertion |
| Change a known focused control to a supported state | General-purpose control of every Mac interface |
| Approve once, decline, and view the verified result | Automatic recovery of pending approvals after quitting |

Action proposals expire after three minutes. Local execution receipts remain in SQLite; a conversation reconnect does not replay an old action. A new request after an uncertain outcome can repeat the intended action, so inspect the target app before retrying.

## Local setup

Requirements: macOS 14+, a Swift 6 toolchain, Docker Compose, an OpenAI project with GPT-Live access, and a TypeSafe API key. The local JWT helper also expects Homebrew OpenSSL at `/opt/homebrew/bin/openssl`.

### 1. Configure the backend

Create `backend/.env` from [backend/example.env](backend/example.env) if it does not exist. Preserve an existing file and its secrets. Configure:

| Variable | Purpose |
| --- | --- |
| `OPENAI_API_KEY` | Server-side OpenAI key with GPT-Live access |
| `TYPESAFE_API_KEY` | Server-side TypeSafe key for action selection |
| `OPENAI_LIVE_MODEL` | Defaults to `gpt-live-1` |
| `TYPESAFE_MODEL` | Defaults to `jev-latest` |
| `MENSO_SAFETY_IDENTIFIER_SALT` | Private, randomly generated salt of at least 32 characters |
| `DB_PASS` | Database password; preserve the password of an existing database |

Provider keys, local JWTs, and signing material must stay out of Git. For local authenticated setup, run from the repository root:

```sh
zsh backend/scripts/generate_local_auth.sh
docker compose --project-directory backend -f backend/compose.yaml up --build -d
```

The helper creates ignored development credentials, valid for 24 hours by default. Compose loads the generated public JWKS configuration; debug Mac builds can read the local token. Production requires a trusted JWT issuer and asymmetric verification—see [backend setup](backend/README.md).

If the database is already running and only API configuration changed, recreate just the API container:

```sh
docker compose --project-directory backend -f backend/compose.yaml up -d --build --force-recreate --no-deps menso-api
```

### 2. Build and install the Mac app

For an Apple Silicon debug build, from the repository root:

```sh
zsh macos/scripts/fetch-cua-driver.sh
swift build --package-path macos --arch arm64
zsh macos/scripts/package-debug-app.sh
open macos/.build/local-app
```

Packaging requires the pinned CUA driver at `macos/Resources/CuaDriver/cua-driver`, which is intentionally not committed. The [driver fetch script](macos/scripts/fetch-cua-driver.sh) documents its inputs. See [Mac setup](macos/README.md) for packaging and release details.

Quit the existing Menso app, move the newly packaged `Menso.app` into `/Applications`, and launch that copy. Running an older installed copy does not pick up source changes. Replacing an ad-hoc signed build may require granting macOS permissions again.

### 3. Use Menso

Start a conversation and allow microphone access. Enable Mac control and grant Accessibility when requested. Say “Open Brave,” then use the native Approve or Decline card. For insertion, first focus the intended text field and dictate the exact text. No preparation form is needed.

Release builds use Settings for the backend URL and product credentials. Existing `live:connect` credentials also authorize action selection; `actions:select` permits selection without voice. `agents:menso:run` is no longer needed. Old `realtime:connect` tokens must be reissued by the trusted issuer.

## Repository

- `macos/`: AppKit/SwiftUI desktop app and trusted local execution.
- `backend/`: TypeSafe selection, GPT-Live session negotiation, verified JWT authentication, and retained Postgres state.
- [Architecture](ARCHITECTURE.md): trust boundaries and the voice/action flow.
- [Implementation status](docs/IMPLEMENTATION_STATUS.md): source changes and outstanding runtime validation.
- [Security](docs/SECURITY.md): authority and continuation invariants.

The floating widget, app/process monitoring, coding-agent dashboards, Claude hooks, dictation, learning management, and scheduled workflows have been removed. Historical SQLite tables and action wire variants are retained for data compatibility; nothing collects new monitoring data.

## Validation status

The TypeSafe migration is source-only: it has not been built, tested, installed, or exercised. Regression tests have been added but not run. Earlier GPT-Live checks do not validate this revision. See [implementation status](docs/IMPLEMENTATION_STATUS.md).

The commands above are instructions, not evidence that setup or validation has succeeded. Repository contributors must obtain explicit user authorization before running tests, builds, linters, formatters, validation scripts, or live checks.

## License

Menso is licensed under the [MIT License](LICENSE). Third-party dependencies retain their respective licenses.
