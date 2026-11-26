# DEBUG normal conversation acceptance

`run_hermes_conversation_live_test.py` runs one opted-in XCTest against the existing,
isolated validation API through an already running conversation relay. It never
starts a relay/gateway, creates a certificate, changes OS trust/network settings,
or uses a robot tool bridge. Release keeps its normal OS trust transport.

Preparation is separate from execution. Complete UI/history/recovery first, freeze
all tracked and new inputs including generated project, then write a final manifest
with `input_digest`, `file_count`, and `live_acceptance_ready: true`. The digest is
SHA-256 of compact, sorted JSON `{path: sha256}` over the same git-listed inputs.
The readiness field is the current Driver's declaration that the UI-complete
candidate is frozen; it does not request another parent approval.

The runner checks that manifest, builds Debug for testing in a **new, empty task
DerivedData path**, verifies app and test signatures, records executable hashes,
and checks input identity afterwards. Do not clone XCBuildData: it can retain old
absolute cleanup paths. A task-owned package cache can be reused.

Before a physical run it freshly checks device connection/pairing/DDI/developer
mode, unlocked state, LAN address, and the existing public certificate's pin,
validity and hostname. The DEBUG transport still performs dedicated-anchor,
pin, hostname and date validation. A failure leaves acceptance incomplete.

Example (paths contain no credential values):

```sh
python3 scripts/run_hermes_conversation_live_test.py \
  --target device --udid DEVICE_ID --out /task/evidence/live-device \
  --credentials /task/runtime/validation-credentials.json \
  --tls-metadata /task/existing-tls/public-metadata.json \
  --endpoint https://CURRENT_APPROVED_LAN_IP:18644 \
  --candidate-manifest /task/final-manifest.json \
  --backend-ready /task/backend-runtime-ready.json \
  --derived-data /task/new-live-derived-data --package-cache /task/packages
```

The credentials file must be 0600, with distinct `client_key` and `upstream_key`.
Only `client_key` is copied into an exclusive 0600 bootstrap inside a 0700 temporary
directory beside the runtime credentials file, outside the evidence directory.
No credential enters
arguments, xctestrun, reports, or the app bundle. The fixture imports then removes
that bootstrap, uses a unique task Keychain service and defaults suite, and cleans
those task settings afterwards. Failed copies/imports can leave a device bootstrap;
the receipt explicitly records that possibility. Ordinary app settings are not used.

The fixture manually creates the **normal production Composition** with fake radio
and camera sources, calls no speech/recognition APIs, and uses its normal reply,
service, history, settings and persisted session identifiers. Its own DEBUG launch
flag suppresses the automatic app scene; the diagnostic echo/bridge probe is not
selected. It checks:

1. Two text turns, recall without resending the nonce, and exactly two user and
   assistant rows from server history. This proves conversation context, not
   long-term memory or skills.
2. A newly constructed consumer and store instances restore that same session and
   remote history. This is **consumer reconstruction**, with `processRestart:false`
   in the result; it does not prove a disk flush or a new process launch.
3. A real completed HTTP poll is held locally, the stream is cancelled, then the
   late response is delivered. No late output is adopted; the real stop request and
   a separately polled actual terminal state are recorded. Completed may win; stop
   ACK does not imply cancelled or erase server history.
4. One accepted POST response is deliberately lost at the DEBUG transport boundary.
   Normal retry uses identical key/body, Hermes reports replay of one run, and remote
   history contains exactly four user/assistant rows including the cancelled remote
   turn. This is **injected response loss/reconnect**, not a physical Wi-Fi outage.
   Hermes deduplication is scoped to the relay's upstream credential. The installed
   API returns `replayed` in its 202 body as well as `Idempotency-Replayed` in headers.

Every scenario must pass in the same result. A success label alone is insufficient;
partial component successes are not whole-app acceptance. Nonzero XCTest, source
change, missing/invalid evidence, or failed cleanup returns failure (66 for invalid
evidence). Partial sanitized results and command logs remain for diagnosis. Run live
once on the final candidate; repeat only a diagnosed failure after a relevant fix.

Offline preparation checks (no opt-in environment flag, backend or device):

```sh
python3 -m unittest discover -s scripts -p test_run_hermes_conversation_live_test.py -v
# After normal project generation, select HermesConversationLiveSupportTests in Xcode.
# HermesConversationLiveTests skips unless the dedicated runner explicitly opts in.
```
