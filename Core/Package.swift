// swift-tools-version: 6.2
import PackageDescription

// BudgetCore holds the money rules shared by the iPhone and Mac apps; TaxCore holds the UK
// property and tax rules on top of it. Both depend only on Foundation so their tests can run
// on macOS and Linux.
let package = Package(
    name: "BudgetCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"]),
        .library(name: "TaxCore", targets: ["TaxCore"])
    ],
    targets: [
        .target(name: "BudgetCore"),
        .target(name: "TaxCore", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
        .testTarget(name: "TaxCoreTests", dependencies: ["TaxCore"])
    ]
)
