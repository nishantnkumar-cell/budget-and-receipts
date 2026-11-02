// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BudgetMacPersonal",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.executable(name: "BudgetMacPersonal", targets: ["BudgetMacPersonal"])],
    targets: [
        .executableTarget(name: "BudgetMacPersonal"),
        .testTarget(name: "BudgetMacPersonalTests", dependencies: ["BudgetMacPersonal"])
    ]
)
