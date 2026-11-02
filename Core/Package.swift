// swift-tools-version: 6.2
import PackageDescription

// BudgetCore holds the money rules shared by the iPhone, Mac and (later) Windows apps.
// It depends only on Foundation so its tests can run on macOS, Linux and Windows.
let package = Package(
    name: "BudgetCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "BudgetCore", targets: ["BudgetCore"])],
    targets: [
        .target(name: "BudgetCore"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"])
    ]
)
