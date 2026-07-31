// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "octoryn-swift",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "OctorynCore", targets: ["OctorynCore"]),
    .library(name: "OctorynSwiftUI", targets: ["OctorynSwiftUI"]),
  ],
  targets: [
    .target(name: "OctorynCore"),
    .target(name: "OctorynSwiftUI", dependencies: ["OctorynCore"]),
    .testTarget(
      name: "OctorynCoreTests",
      dependencies: ["OctorynCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "OctorynSwiftUITests",
      dependencies: ["OctorynSwiftUI", "OctorynCore"]
    ),
  ]
)
