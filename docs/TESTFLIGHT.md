# iPhone installation and signing

## Current decision

The user declined paid Apple Developer membership. Enrollment, payment, App Store Connect setup and TestFlight upload are stopped. No purchase was made. The existing identifier and installed iPhone app remain untouched.

Free development signing continues to require re-signing/reinstalling when the provisioning profile expires (the observed profile lasts seven days). Keep the same identifier and assess unsynchronized data before updating the installation. TestFlight and App Store distribution require paid membership, so they are not part of the active release plan. macOS and Android builds remain available without purchasing Apple membership.

## Verified state

The signed-in Apple account showed **Join the Apple Developer Program**, with no active paid membership. Apple's official web enrollment is open at the personal-information step. Enrollment, identity verification, legal agreements and payment are user steps; no purchase was made.

The existing project uses `com.example.syncTaskApp` and signing team `35YZWRU6G4`. These are preserved. The local development profile was created September 13, 2026 and expired September 20, 2026 (`LocalProvision=true`), confirming the seven-day signing problem. It is independent of PocketBase authentication token expiration.

No App Store Connect app, TestFlight group, signed release archive, upload, or compliance declaration has been submitted. A paid team's bundle-ID availability must be confirmed after enrollment; do not invent or change identifiers to make signing pass.

## Optional enrollment reference (only if the user later changes their decision)

Use [Apple's official enrollment page](https://developer.apple.com/programs/enroll/) or the Apple Developer app. Provide your legal information and complete identity checks yourself. Verify the fee shown by Apple for your country and complete payment only when you choose to proceed. Wait until the account shows an active Developer Program membership. If you use a different Apple Account for an existing paid membership, sign in to that account instead.

## Preserve phone data first

Do not delete the installed app. Before replacement, use the original app to synchronize while its profile is valid if possible; otherwise assess a device backup and re-signing the same identifier. Pending Hive data may exist only on the iPhone and is not protected merely by backing up PocketBase. Replacing an app with the same bundle identifier may retain its sandbox, but a different paid team, signing transition, or uninstall may affect sandbox/Keychain access. Confirm the actual device backup and pending tasks before installing over it. No device app was removed during this implementation.

## Optional TestFlight workflow (inactive)

1. In Xcode Settings > Accounts, select the paid account and refresh certificates/profiles. Open `ios/Runner.xcworkspace`, select Runner > Signing & Capabilities, and choose the paid team with automatic signing. Verify the existing bundle identifier can be registered to that team and the Keychain entitlement is valid. If it cannot, assess migration/data risk before choosing another identifier.
2. In App Store Connect, create an iOS app record with the verified registered bundle ID, language, app name and a private unique SKU. Do not reuse a different app's record.
3. Configure the approved private HTTPS assistant endpoint and PocketBase schema. Set a new, monotonically increasing build number. Validate the iPhone's Tailscale connectivity.
4. Build and archive:

```sh
flutter build ipa --release --build-name=1.0.0 --build-number=2 --dart-define=AI_BACKEND_URL=https://YOUR-SERVER.YOUR-TAILNET.ts.net --dart-define=TASK_SCHEDULING_ENABLED=true
```

Use a higher build number if 2 was already uploaded. `flutter build ios --release --no-codesign` verifies compilation only and cannot produce an installable TestFlight build. In Xcode Organizer use Distribute App > App Store Connect > Upload for the signed archive; review validations before uploading.

5. Wait for processing, then enter accurate beta description, feedback email, contact details and “What to Test.” Do not guess compliance declarations. The app uses HTTPS, platform Keychain/encrypted Android storage and Tailscale networking. Review [Apple export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) for the complete release and dependencies. `ITSAppUsesNonExemptEncryption` is intentionally not hardcoded until the applicable declaration is assessed.
6. Create an internal TestFlight group, add your own eligible App Store Connect account, assign the processed build and enable automatic distribution if desired. Install Apple's TestFlight app on the iPhone, accept the invitation, and install/update after confirming the data-preservation plan.
7. Test login, offline creation/edit/completion, synchronization with a desktop, real-time changes, AI previews/confirmation, due dates, history, and failed network/provider requests on the real device.

## Expiration and long-term distribution

Each TestFlight build is available for **up to 90 days**. Upload and install a new build before expiration. TestFlight does not provide indefinite installation. [Apple's TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) establishes this limit.

App Store distribution is a better fit for a stable long-term app because installed production builds do not have TestFlight's 90-day beta expiry. It requires App Review, privacy disclosures, ongoing maintenance and an active developer account for distribution. This app currently depends on a private tailnet and a private login: plan reviewer access and an appropriate distribution approach before public submission. A public App Store listing should not expose your PocketBase server or API secrets merely to enable review. Keep TestFlight for beta iteration while evaluating the intended audience and review access.
