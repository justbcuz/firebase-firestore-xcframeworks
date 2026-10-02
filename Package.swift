// swift-tools-version:5.9
// firebase-firestore-xcframeworks — overlay on firebase-ios-sdk 12.19.x that
// swaps FirebaseFirestore for a binary path with visionOS slices.
//
// Architecture:
//   - Five `firestore_*` binaryTargets for Firestore's native C/C++ deps.
//     Names prefixed to avoid collisions with upstream firebase-ios-sdk's
//     external package deps (abseil-cpp-binary, grpc-binary, firebase/leveldb).
//   - `_FirebaseFirestoreInternal` binaryTarget — Google's six untouched
//     iOS/macOS/Catalyst/tvOS slices merged with our two visionOS slices.
//     The framework's modulemap module identifier is still
//     `FirebaseFirestoreInternal` (intrinsic to the binary). SPM target name
//     is the underscored variant to avoid collision.
//   - `_FirebaseFirestoreInternalWrapper` source target (Obj-C shim around
//     the binary's headers). Renamed in SPM space; reachable from Firestore
//     Swift code via a moduleAlias.
//   - `FirebaseFirestorePrebuilt` source target (Swift wrapper). Renamed
//     from upstream's `FirebaseFirestore` to avoid SPM target-name collision
//     with firebase-ios-sdk's own target of the same name, which is in the
//     same dep graph (pulled by FirebaseCore/Auth/RemoteConfig). Consumer
//     code imports `FirebaseFirestorePrebuilt` instead of `FirebaseFirestore`.
//   - Firebase Core / SharedSwift / CoreExtension / AppCheckInterop /
//     AuthInterop come from upstream firebase-ios-sdk, pulled either by
//     direct product references (FirebaseCore) or transitively via heavier
//     products that bring internal-only targets into the build graph
//     (FirebaseAuth → CoreExtension, AppCheckInterop, AuthInterop;
//     FirebaseRemoteConfig → SharedSwift). Source-compile cost: seconds, on
//     every platform including visionOS.
//
// HACK — openssl_grpc modulemap module identifier was renamed from
// `BoringSSL-GRPC` to `openssl_grpc` in every slice via
// scripts/normalize-openssl-grpc-modulemap.sh. Re-run that script if the
// xcframework is rebuilt or its iOS slices refreshed from Google's release.
//
// HACK — grpc.xcframework's visionOS slices were originally built with
// libabsl_*.a bundled into the binary (per scripts/build-grpc.sh, mirroring
// Google's iOS build). That created duplicate-symbol link errors in
// consumer apps because absl.xcframework also provides those symbols on
// visionOS. Fix: scripts/build-grpc.sh no longer bundles libabsl_*.a;
// absl symbols come exclusively from firestore_absl. Google's iOS slices
// are untouched. If grpc is ever rebuilt from scratch, ensure the
// libabsl_*.a bundling line stays removed.
//
// HACK — absl.xcframework's visionOS slices are built with
// ABSL_OPTION_USE_STD_* forced to 0 (see scripts/build-absl.sh). Default
// auto-detect (=2) chooses std:: aliases when compiled with C++17, but
// gRPC's bundled absl auto-detects differently and uses distinct classes,
// producing mismatched mangled names at link time. Forcing 0 makes ABI
// deterministic and matches Google's iOS/macOS/tvOS slices.

import PackageDescription

let firebaseVersion = "12.19.1"

let package = Package(
    name: "firebase-firestore-xcframeworks",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        // Product and target are both named `FirebaseFirestorePrebuilt` —
        // a deliberate rename from upstream's `FirebaseFirestore` to avoid
        // SPM target-name and PIF product-name collisions with
        // firebase-ios-sdk (which ships its own `FirebaseFirestore` in the
        // same dep graph). Consumers `import FirebaseFirestorePrebuilt`
        // wherever upstream docs say `import FirebaseFirestore`. API
        // surface is otherwise identical to upstream Firestore.
        .library(name: "FirebaseFirestorePrebuilt", targets: ["FirebaseFirestorePrebuilt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "12.19.1"),
        .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0" ..< "2.30911.0"),
    ],
    targets: [
        // MARK: - Local binaryTargets

        .binaryTarget(name: "firestore_absl",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/absl.xcframework.zip",
                      checksum: "6179405f825f1691db14b8a0a17b358d7bffbef63b2a07a59efd72a308656d54"),
        .binaryTarget(name: "firestore_openssl_grpc",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/openssl_grpc.xcframework.zip",
                      checksum: "7ec1548b80c57e18bb01685febc8c8f9b9afe6d6a729992770bec481c2bfb95f"),
        .binaryTarget(name: "firestore_grpc",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/grpc.xcframework.zip",
                      checksum: "dd768cdcd694ee9104862c692855a98e9afcbcb1db3ab30e68a85cea9cc7dad1"),
        .binaryTarget(name: "firestore_grpcpp",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/grpcpp.xcframework.zip",
                      checksum: "5b532bdd546416ad9c27e5a0171b78dc04fdcc46f8224ad558668840c73677fa"),
        .binaryTarget(name: "firestore_leveldb",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/leveldb.xcframework.zip",
                      checksum: "ccb6cb6b32e2fc42fc1aab84294e66353ec6a7feb156628b9a797b29b5d54f0f"),
        .binaryTarget(name: "_FirebaseFirestoreInternal",
                      url: "https://github.com/justbcuz/firebase-firestore-xcframeworks/releases/download/12.19.1/FirebaseFirestoreInternal.xcframework.zip",
                      checksum: "5dbe903992b2d6a3329c4594fc5f4654f4903b2d668b6fc7156907525edfdbac"),

        // MARK: - Firestore Obj-C wrapper around the binary

        // The vendored Firestore Swift sources do:
        //   #if SWIFT_PACKAGE
        //     @_exported import FirebaseFirestoreInternalWrapper
        //   #else
        //     @_exported import FirebaseFirestoreInternal
        //   #endif
        // SWIFT_PACKAGE is always defined under SPM, so a module named
        // FirebaseFirestoreInternalWrapper must be visible to our Swift
        // wrapper. We name the SPM target `_FirebaseFirestoreInternalWrapper`
        // (to avoid collision with upstream's same-named target) and use
        // moduleAliases at the dependency edge to make it appear as
        // `FirebaseFirestoreInternalWrapper` to compilers downstream.
        .target(
            name: "_FirebaseFirestoreInternalWrapper",
            dependencies: [.target(
                name: "_FirebaseFirestoreInternal",
                condition: .when(platforms: [.iOS, .macCatalyst, .tvOS, .macOS, .visionOS])
            )],
            path: "FirebaseFirestoreInternal",
            publicHeadersPath: "."
        ),

        // MARK: - Firestore Swift wrapper

        .target(
            name: "FirebaseFirestorePrebuilt",
            dependencies: [
                "_FirebaseFirestoreInternalWrapper",
                "firestore_absl",
                "firestore_grpc",
                "firestore_grpcpp",
                "firestore_openssl_grpc",
                "firestore_leveldb",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                // FirebaseAuth product transitively pulls FirebaseAppCheckInterop,
                // FirebaseAuthInterop, FirebaseCoreExtension — internal-only
                // targets that aren't exposed as products by upstream.
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                // FirebaseRemoteConfig transitively pulls FirebaseSharedSwift.
                .product(name: "FirebaseRemoteConfig", package: "firebase-ios-sdk"),
                .product(name: "nanopb", package: "nanopb"),
            ],
            path: "Firestore/Swift/Source",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("SystemConfiguration",
                                 .when(platforms: [.iOS, .macOS, .tvOS, .visionOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
