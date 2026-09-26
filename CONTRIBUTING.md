# Contributing

## Branches and worktrees

Branch from `main` and open a pull request; nobody pushes to `main` directly. One person or agent writes to a branch at a time. Parallel work uses separate worktrees:

```sh
git worktree add ../house-scanning-<topic> -b <name>/<topic> origin/main
```

Clone with the landing page submodule, or fetch it later with `git submodule update --init sites/landing`.

## This repository is public

Never commit photos, video, scans or measurements of a real home, street addresses, meter or account numbers, or the materials Base gave the team. Base's materials stay in `private/`, real captures in `captures/` or `fixtures/real/`, and experiment outputs in `data/`. Git ignores all four. Test fixtures are synthetic.

## Pull requests

Keep a pull request focused. A larger change is fine when its parts belong together.

State what the old code did before describing the new behavior. Link the reviewed files where that helps. Show only changed UI behavior, list known gaps, and report commands that actually ran with their results.

The `size:*` label describes the effective diff. It is a review signal, not a merge gate. Do not set it by hand.

## Checks

| Check | Runs on GitHub when | Local command |
| --- | --- | --- |
| Server checks | `server/` changes | `make server` |
| Web checks | `web/` changes | `make web` |
| iOS build | `ios/` changes | `make ios` |
| Sync label definitions | `.github/labels.json` changes on `main` | none |
| Label PR size | a pull request opens or updates | none |
| TestFlight | someone runs it from the Actions tab | none |

`make check` runs the three local suites. They need uv, Node 24 with pnpm, and Xcode 26 or newer; each directory's README has details. No check is required by branch rules yet. Don't call one required until the rules require its status.

Keep workflows that run pull-request code away from production credentials and destructive external systems. A green CI run is evidence for the checks it ran, not proof that a capture works on a real house.

## Distribution

`.github/workflows/testflight.yml` archives one app, signs it and uploads it to TestFlight. It runs only when someone starts it by hand. The build number is the workflow's run number and attempt, such as `12.1`, so each upload, reruns included, is higher than the last.

| App | Project | Bundle id |
| --- | --- | --- |
| House Scan (`house-scan`) | `ios/` | `<BUNDLE_ID_PREFIX>.housescan` |
| Measure Lab (`measure-lab`) | `experiments/measure-lab/` | `<BUNDLE_ID_PREFIX>.measurelab` |

### Before the first upload

Each app needs an app icon, because App Store Connect rejects a build without one. Measure Lab has one in `experiments/measure-lab/MeasureLab/Assets.xcassets`, added in #7. House Scan does not yet. It needs an `AppIcon` set with a 1024×1024 image in an asset catalog inside `ios/HouseScan/`, added by the lane A owner. The project already sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

Neither `Info.plist` declares `ITSAppUsesNonExemptEncryption`. Until one does, every new build waits in TestFlight under "Missing Compliance" until someone answers the encryption question on the build page. Setting the key to `false` skips that step for an app that uses only HTTPS and Apple's system encryption.

### One-time setup

The account holder does this once, in order.

1. **Create an App Store Connect API key.** In [App Store Connect](https://appstoreconnect.apple.com) > Users and Access > Integrations > App Store Connect API, create a team key with the **Admin** role. The export step signs with a cloud-managed distribution certificate, and API keys with the App Manager role get `Cloud signing permission error` because keys have no setting to grant that access. Download the `.p8` file (Apple offers it once) and note the Key ID and the Issuer ID shown above the key list.
2. **Add the `testflight` environment.** In the GitHub repository, open Settings > Environments > New environment and name it `testflight`. Set two protection rules:

   - Required reviewers: add Sam. Every run then pauses until he approves it, and GitHub releases no secret to the job before that. Leave "Prevent self-review" off so he can approve runs he starts.
   - Deployment branches and tags: choose Selected branches and add `main`, so the key only signs reviewed code.

   An Admin key can sign and upload for the whole team, so it is acceptable here only because both rules hold. A run needs Sam's approval and code already merged to `main`. Then add these:

   | Kind | Name | Value |
   | --- | --- | --- |
   | Secret | `ASC_KEY_ID` | the Key ID |
   | Secret | `ASC_ISSUER_ID` | the Issuer ID |
   | Secret | `ASC_KEY_P8` | output of `base64 -i AuthKey_<KEY_ID>.p8` |
   | Variable | `APPLE_TEAM_ID` | the 10-character Team ID from developer.apple.com > Account > Membership details |
   | Variable | `BUNDLE_ID_PREFIX` | a reverse-DNS prefix the team can register, such as `com.yourname` |

   Delete the downloaded `.p8` from Downloads once the secret is saved. Never commit it.
3. **Register a device.** The archive step signs for development first and asks Apple for a development profile, which Apple refuses to a team with no registered devices. Running either app on your iPhone from Xcode once registers it. You can also add the device under Certificates, Identifiers & Profiles > Devices.
4. **Create the app records.** App Store Connect has no API for creating apps. First register the two explicit App IDs, `<BUNDLE_ID_PREFIX>.housescan` and `<BUNDLE_ID_PREFIX>.measurelab`, under Certificates, Identifiers & Profiles > Identifiers. Then in App Store Connect > Apps > New App, create **House Scan** and **Measure Lab** for iOS and pick the matching bundle id for each. The name must be unique across the App Store, so add a suffix if Apple says it is taken.
5. **Add internal testers.** In each app's TestFlight tab, create an internal group and add team members. Internal testers must already be users in App Store Connect. Turn on automatic distribution so new builds reach the group without another click.
6. **Run the workflow.** Open Actions > TestFlight > Run workflow, pick `main` and the app, and start it. Sam approves the pending deployment on the run page. The run summary reports the uploaded build number. The build shows in TestFlight once Apple finishes processing it.

Measure Lab is only on its pull request branch until that merges, and the environment rule above only lets `main` use the key. Its uploads start working once it lands on `main`.

### Upkeep

Each run happens on a fresh runner, so the archive step creates a new "Apple Development: Created via API" certificate every time. Revoke old ones under Certificates, Identifiers & Profiles > Certificates when the list grows. TestFlight builds carry the distribution signature, so revoking these does not affect them.
