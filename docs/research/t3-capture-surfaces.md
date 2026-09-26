# Capture surfaces: what each phone surface can measure

Most homeowners don't have a LiDAR iPhone, and they reach Base through a link. This note compares the places a capture can run, so the team can decide which surface serves which phone. The references below were collected on 2026-09-25. Nobody has tested these capabilities on a phone for this project yet.

## Capabilities by surface

| Surface | AR tracking in real units | Planes and raycasts | Depth or mesh | Camera frames with pose | Entry friction |
| --- | --- | --- | --- | --- | --- |
| iOS app, no LiDAR | Yes (ARKit world tracking) | Yes | No | Yes | App Store or TestFlight install |
| iOS app, LiDAR (Pro models) | Yes | Yes | Yes (scene depth, mesh) | Yes | Same |
| App Clip on iOS 17+ | Yes, ARKit and camera allowed | Yes | Unverified inside a clip; would need a LiDAR phone | Yes | No install; opens from a link, a Messages bubble, a QR code or NFC |
| iPhone Safari | No: Safari 27 still has no WebXR AR | No | No | Video without pose | None |
| Android Chrome | Yes (WebXR on ARCore phones) | Yes, plane detection since Chrome 147 | Depth from motion | Yes (raw camera access) | None |
| Android app | Yes (ARCore) | Yes | Depth from motion, best at 0.5 to 5 m | Yes | Play Store install; Play Instant ended in December 2025 |
| Photos only (Base today) | No | No | Model estimates only | No pose | A link with 7 to 9 photos |

CI builds and unit-tests the iOS app and the web toolchain, and agents can drive web pages in a browser. AR tracking runs only on a real phone outdoors, so every end-to-end check of the AR path needs a person holding the phone.

## What the table means for the product

- **On iPhone, AR needs native code.** The App Clip gets it without a full install. A clip opened from a QR code or NFC tag must stay under 15 MB; a clip opened only from links can reach 100 MB on iOS 17 and later. Uploads must finish in the foreground, because clips can't use background transfers.
- **Android Chrome is a no-install capture candidate.** Before treating it as an alternative to native ARCore, verify saved camera images with matching poses and calibration, negotiated depth export, and interrupted-session recovery on supported devices. Until then, native Kotlin remains the proposed Android capture path.
- **Everyone else falls back to photos or video processed on the server.** The best learned models report roughly 13 to 15 percent scale error on research benchmarks. Nobody has measured them on house walls, so the photo baseline gets scored against the same tape-measured spots before anyone trusts an error bound.
- **No published test covers ARKit accuracy without LiDAR on an exterior walk like this one.** We have to measure it ourselves with a tape before the rules' margins can rely on it.
- **Generative world models are for pictures, not measurements.** World Labs Marble and Atlas and Runway's GWM fill in regions the camera never saw. A filled-in corner is not evidence that the corner is clear.

## Reaching Android later

Keep Swift capture for the hackathon. Android work starts after one iPhone capture runs end to end, and it should not change the server.

- **Add a Kotlin ARCore capture adapter.** ARCore gives metric poses, planes, hit tests and camera intrinsics without a depth sensor. It has no ARKit-style scene mesh, and [raw depth](https://developers.google.com/ar/develop/java/depth/raw-depth) usually has zero confidence on textureless walls. Facing gaps and headroom stay UNSURE unless another source measures them. The adapter can run in a native Android app or behind an Expo shell.
- **Keep the upload format independent of ARKit and LiDAR.** A minimal, versioned manifest records the capture provider, device, session ID, units, and each frame's timestamp, pose, intrinsics and image size. Depth and mesh are optional. A missing mesh means unknown, never clear space.
- **Treat Android WebXR export as a short experiment, not parity.** The table shows what Chrome exposes. The proposed WebXR capture path has not demonstrated saved camera images with matching poses and calibration. Test that first: [raw camera access](https://immersive-web.github.io/raw-camera-access/), [depth sensing](https://www.w3.org/TR/webxr-depth-sensing-1/) on both its CPU and GPU paths, reprojection of saved frames, and an interrupted session. If export fails, the phone routes to photos before the walk starts.
- **Guided photos stay the broadest fallback**, including phones without ARCore. The app should check the photos for the deciding views before the homeowner leaves.

## Closest prior art

- Base's current flow sends a link that asks for 7 to 9 photos: the meter, both sides of the installation area, the adjacent wall, the main breaker and the disconnect. Engineering follows up within two days when it needs more.
- Hover asks for at least eight guided exterior photos and returns a measured model, claiming about 5 percent accuracy after 2 to 4 hours of processing.
- SiteCapture and Qmerit send homeowners a browser link for photo surveys with no app, which is the friction bar an App Clip has to match.

## Sources

- ARKit without LiDAR: [world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking), [plane detection](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/planedetection), [raycasting](https://developer.apple.com/documentation/arkit/raycasting), [scene reconstruction needs LiDAR](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction%28_%3A%29)
- App Clips: [size limits](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes), [allowed functionality](https://developer.apple.com/documentation/appclip/choosing-the-right-functionality-for-your-app-clip), [testing](https://developer.apple.com/documentation/appclip/testing-the-launch-experience-of-your-app-clip)
- iPhone Safari: [Apple forum answer on immersive-ar](https://developer.apple.com/forums/thread/756850?answerId=790772022#790772022), [Safari 27.0 features](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)
- Android: [WebXR on ARCore](https://developers.google.com/ar/develop/webxr/arcore-comparison), [Chrome 147 release notes](https://developer.chrome.com/release-notes/147), [ARCore Depth API](https://developers.google.com/ar/develop/depth), [Play Instant notice](https://developer.android.com/topic/google-play-instant)
- World models: [Marble API FAQ](https://docs.worldlabs.ai/api/faq), [Atlas announcement](https://www.worldlabs.ai/blog/atlas), [Runway GWM-1](https://runway.com/research/introducing-runway-gwm-1)
- Prior art: [Base photo review](https://help.basepowercompany.com/en/articles/10280641), [Hover exterior scans](https://help.hover.to/en/articles/9185612-exterior-scans), [Hover accuracy](https://hover.to/architects/), [SiteCapture self-surveys](https://sitecapture.com/self-surveys-inspections/)
