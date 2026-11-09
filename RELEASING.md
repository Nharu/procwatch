# Releasing procwatch

Releases are cut by pushing a version tag. The `release.yml` workflow then builds the app, signs
it with a Developer ID, notarizes and staples it, uploads the zip to a GitHub Release, and updates
the cask in the `Nharu/homebrew-tap` repository.

## Secrets

The release workflow checks all six repository secrets before it builds anything. If any is empty
it fails and names every missing secret, before anything is published.

| Secret | What it holds |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported as a `.p12` file and base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the `.p12` file |
| `NOTARY_APPLE_ID` | The Apple ID email of the developer account used for notarization |
| `NOTARY_TEAM_ID` | The 10-character Team ID of that developer account |
| `NOTARY_APP_PASSWORD` | An app-specific password for that Apple ID |
| `HOMEBREW_TAP_TOKEN` | A fine-grained personal access token that can write to `Nharu/homebrew-tap` |

How to make each one:

- **Developer ID certificate** — create a *Developer ID Application* certificate in the Apple
  Developer portal (Certificates, Identifiers & Profiles) and install it. In Keychain Access,
  select the certificate together with its private key, choose *Export*, save it as
  `developer-id.p12` and set a password. Encode it:

  ```sh
  base64 -i developer-id.p12 | pbcopy
  ```

  The clipboard now holds `DEVELOPER_ID_P12_BASE64`; the export password is
  `DEVELOPER_ID_P12_PASSWORD`. Delete the `.p12` file afterwards.
- **App-specific password** — sign in at <https://account.apple.com>, open *Sign-In and
  Security* → *App-Specific Passwords* and generate one (for example, labelled
  `procwatch notarization`).
- **Team ID** — shown on the *Membership details* page of <https://developer.apple.com/account>.
- **Tap token** — at GitHub *Settings* → *Developer settings* → *Fine-grained tokens*, create a
  token whose repository access is only `Nharu/homebrew-tap`, with the repository permission
  *Contents: Read and write* and nothing else.

Register each secret on this repository:

```sh
gh secret set DEVELOPER_ID_P12_BASE64 --repo Nharu/procwatch
gh secret set DEVELOPER_ID_P12_PASSWORD --repo Nharu/procwatch
gh secret set NOTARY_APPLE_ID --repo Nharu/procwatch
gh secret set NOTARY_TEAM_ID --repo Nharu/procwatch
gh secret set NOTARY_APP_PASSWORD --repo Nharu/procwatch
gh secret set HOMEBREW_TAP_TOKEN --repo Nharu/procwatch
```

`gh secret set` prompts for the value, so it does not end up in your shell history.

## Tap repository

The cask lives in the public tap `Nharu/homebrew-tap`, which users reach as `nharu/tap`.
Create it once, initialized with a README so it has a default branch:

```sh
gh repo create Nharu/homebrew-tap --public --add-readme --description "Homebrew tap for procwatch"
```

The workflow writes `Casks/procwatch.rb` into it; you do not need to add the file yourself.

## Cutting a release

Tags must be `v<major>.<minor>.<patch>` with three numbers (for example `v0.1.0`). Any other tag,
such as `v1.0.0-beta.1`, makes the release fail. The version in the app bundle comes from the tag.

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The workflow runs only on `v*` tag pushes and has two jobs.

- `release` (macOS):
  1. checks that all six secrets are set;
  2. checks the tag format and takes the version from it;
  3. imports the certificate into a temporary keychain and finds the Developer ID Application identity;
  4. builds and signs the app with `app/scripts/build-app.sh` (hardened runtime, timestamp);
  5. submits the zipped app to Apple's notary service and waits for the result;
  6. staples the ticket, verifies it with `stapler validate` and `spctl --assess`, and zips the
     stapled app as `procwatch-<version>.zip`;
  7. creates the GitHub Release for the tag with that zip and generated notes;
  8. always deletes the temporary keychain and certificate file at the end.
- `tap` (Linux, after `release`): renders `packaging/homebrew/procwatch.rb` with the version and
  the zip's SHA-256 into `Casks/procwatch.rb` of the tap and pushes a `procwatch <version>` commit
  when the file changed.

### When a run fails

- **Only the `tap` job failed** (for example the token expired): fix the cause, then re-run just
  the failed job. The Release already exists and is not touched.

  ```sh
  gh run rerun <run-id> --failed --repo Nharu/procwatch
  ```

- **The `release` job failed before the Release was created** (missing secret, notarization
  rejected, signing problem): fix the cause and re-run the same run with
  `gh run rerun <run-id> --repo Nharu/procwatch`. If the fix needs a code change, delete the tag
  locally and on GitHub, merge the fix, and push the tag again on the new commit.
- If notarization is rejected, the job prints the notary log; read it for the offending file.

### Version in local builds

`app/scripts/build-app.sh` puts the version into the bundle. It uses `PROCWATCH_VERSION` when set
(it must be three dot-separated numbers), otherwise the nearest `v<major>.<minor>.<patch>` tag
without the `v`, otherwise `0.0.0`. `PROCWATCH_SIGN_IDENTITY` selects the signing identity; without
it the bundle is signed ad hoc.

## Pre-release checklist

Things a person has to do before the first public release:

- [ ] Register the five signing and notarization secrets
- [ ] Create the tap repository and register `HOMEBREW_TAP_TOKEN`
- [ ] Set the repository description and topics
  - Description: `macOS menu bar app that flags runaway processes spawned by Claude Code — alerts only, never kills.`
  - Topics: `macos`, `menu-bar`, `swift`, `appkit`, `claude-code`, `process-monitor`, `cpu-monitor`
  - Command:

    ```sh
    gh repo edit Nharu/procwatch --description "macOS menu bar app that flags runaway processes spawned by Claude Code — alerts only, never kills." --add-topic macos --add-topic menu-bar --add-topic swift --add-topic appkit --add-topic claude-code --add-topic process-monitor --add-topic cpu-monitor
    ```

- [ ] Add a menu bar screenshot to both READMEs (at the `<!-- screenshot: menu bar dropdown -->` comment)
- [ ] Make the repository public

  ```sh
  gh repo edit Nharu/procwatch --visibility public --accept-visibility-change-consequences
  ```

- [ ] Push the first tag (see [Cutting a release](#cutting-a-release))
