//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
@_spi(SwiftPMInternal) import CoreCommands
import Foundation
import PackageModel
import SPMBuildCore
import TSCBasic

import func TSCLibc.exit

public struct NucleusSwiftPMDriverRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case resolve
        case buildProduct
        case buildTarget
        case test
        case productsPath
    }

    public struct TestOptions: Codable, Sendable {
        public let product: String?
        public let filters: [String]
        public let skips: [String]
        public let parallel: Bool
        public let workers: Int?
        public let xUnitOutputPath: String?

        public init(
            product: String? = nil,
            filters: [String] = [],
            skips: [String] = [],
            parallel: Bool = false,
            workers: Int? = nil,
            xUnitOutputPath: String? = nil
        ) {
            self.product = product
            self.filters = filters
            self.skips = skips
            self.parallel = parallel
            self.workers = workers
            self.xUnitOutputPath = xUnitOutputPath
        }
    }

    public let operation: Operation
    public let selection: String?
    public let test: TestOptions?
    public let packagePath: String
    public let scratchPath: String
    public let cachePath: String?
    public let swiftSDKsPath: String?
    public let buildSystem: String
    public let configuration: String
    public let jobs: UInt32
    public let debugInformationFormat: String?
    public let targetTriple: String?
    public let swiftSDK: String?
    public let toolsetPaths: [String]
    public let staticSwiftStandardLibrary: Bool
    public let forceResolvedVersions: Bool
    public let sanitizer: String?
    public let traits: [String]
    public let swiftCompilerFlags: [String]
    public let cCompilerFlags: [String]
    public let cxxCompilerFlags: [String]
    public let linkerFlags: [String]
}

public struct NucleusSwiftPMDriverEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case started
        case progress
        case commandStarted
        case commandFinished
        case completed
    }

    public let kind: Kind
    public let message: String?
    public let target: String?
    public let success: Bool?
    public let productsPath: String?

    init(
        kind: Kind,
        message: String? = nil,
        target: String? = nil,
        success: Bool? = nil,
        productsPath: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.target = target
        self.success = success
        self.productsPath = productsPath
    }
}

private final class NucleusDriverEventWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    func emit(_ event: NucleusSwiftPMDriverEvent) {
        lock.withLock {
            do {
                var data = try encoder.encode(event)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                fputs("nucleus SwiftPM driver could not write an event: \(error)\n", stderr)
            }
        }
    }
}

private final class NucleusBuildSystemDelegate: BuildSystemDelegate {
    private let events: NucleusDriverEventWriter

    init(events: NucleusDriverEventWriter) {
        self.events = events
    }

    func buildSystem(_ buildSystem: BuildSystem, didStartCommand command: BuildSystemCommand) {
        events.emit(
            .init(
                kind: .commandStarted,
                message: command.description,
                target: command.targetName))
    }

    func buildSystem(_ buildSystem: BuildSystem, didUpdateTaskProgress text: String) {
        events.emit(.init(kind: .progress, message: text))
    }

    func buildSystem(_ buildSystem: BuildSystem, didFinishCommand command: BuildSystemCommand) {
        events.emit(
            .init(
                kind: .commandFinished,
                message: command.description,
                target: command.targetName))
    }
}

/// The decoded request and event stream bound around the running driver command.
///
/// `AsyncSwiftCommand` refines `ParsableArguments`, so a conforming type must be
/// default-constructible and `Decodable`. The driver is never parsed from a
/// command line — it is handed an already-decoded request — so its non-parsable
/// inputs travel beside the command instead of becoming stored properties that
/// could not satisfy either conformance.
private enum NucleusDriverContext {
    fileprivate struct Value: Sendable {
        fileprivate let request: NucleusSwiftPMDriverRequest
        fileprivate let events: NucleusDriverEventWriter
    }

    @TaskLocal static var current: Value?

    static func required() throws -> Value {
        guard let current else {
            throw StringError("nucleus driver ran without a bound request context")
        }
        return current
    }
}

private func nucleusGlobalOptions(
    for request: NucleusSwiftPMDriverRequest
) throws -> GlobalOptions {
    guard
        let buildSystem = NucleusSwiftPMInvocationOptions.BuildSystem(
            rawValue: request.buildSystem)
    else {
        throw StringError("unknown build system '\(request.buildSystem)'")
    }
    guard
        let configuration = NucleusSwiftPMInvocationOptions.Configuration(
            rawValue: request.configuration)
    else {
        throw StringError("unknown build configuration '\(request.configuration)'")
    }
    return try GlobalOptions(
        nucleus: .init(
            packagePath: request.packagePath,
            scratchPath: request.scratchPath,
            cachePath: request.cachePath,
            swiftSDKsPath: request.swiftSDKsPath,
            buildSystem: buildSystem,
            configuration: configuration,
            jobs: request.jobs,
            debugInformationFormat: request.debugInformationFormat,
            targetTriple: request.targetTriple,
            swiftSDK: request.swiftSDK,
            toolsetPaths: request.toolsetPaths,
            forceResolvedVersions: request.forceResolvedVersions,
            sanitizer: request.sanitizer,
            traits: request.traits,
            swiftCompilerFlags: request.swiftCompilerFlags,
            cCompilerFlags: request.cCompilerFlags,
            cxxCompilerFlags: request.cxxCompilerFlags,
            linkerFlags: request.linkerFlags))
}

private struct NucleusDriverCommand: AsyncSwiftCommand {
    static let configuration = CommandConfiguration(shouldDisplay: false)

    @OptionGroup var globalOptions: GlobalOptions

    func buildSystemProvider(_ swiftCommandState: SwiftCommandState) throws -> BuildSystemProvider {
        swiftCommandState.defaultBuildSystemProvider
    }

    func run(_ state: SwiftCommandState) async throws {
        let context = try NucleusDriverContext.required()
        let request = context.request
        let events = context.events
        events.emit(.init(kind: .started, message: request.operation.rawValue))
        switch request.operation {
        case .resolve:
            try await state.resolve()
            events.emit(.init(kind: .completed, success: true))
        case .buildProduct, .buildTarget:
            let selection = try requiredSelection(request)
            let delegate = NucleusBuildSystemDelegate(events: events)
            let buildSystem = try await state.createBuildSystem(
                explicitProduct: request.operation == .buildProduct ? selection : nil,
                shouldLinkStaticSwiftStdlib: request.staticSwiftStandardLibrary,
                delegate: delegate)
            let subset: BuildSubset =
                request.operation == .buildProduct
                ? .product(selection)
                : .target(selection)
            try await buildSystem.build(subset: subset, buildOutputs: [])
            events.emit(.init(kind: .completed, success: true))
        case .test:
            let options = try requiredTestOptions(request)
            // Parsed for its declared defaults, for the same reason
            // `GlobalOptions.init(nucleus:)` is: every option group below is
            // assigned through, and a directly constructed command still holds
            // declarations that trap when read.
            var command = try SwiftTestCommand.parse([])
            command.options.globalOptions = globalOptions
            command.options.sharedOptions.testProduct = options.product
            command.options.filter = options.filters
            command.options._testCaseSkip = options.skips
            command.options.shouldRunInParallel = options.parallel
            command.options.numberOfWorkers = options.workers
            command.options.xUnitOutput = try options.xUnitOutputPath.map(
                AbsolutePath.init(validating:))
            try await command.run(state)
            events.emit(.init(kind: .completed, success: true))
        case .productsPath:
            let buildSystem = try await state.createBuildSystem()
            let productsPath = try await buildSystem.buildProductsPath(
                for: state.productsBuildParameters)
            if CommandLine.arguments.contains("--export-products") {
                print(productsPath.pathString)
            }
            let publishedProductsPath =
                ProcessInfo.processInfo.environment["NUCLEUS_SWIFTPM_HOST_PRODUCTS"]
                ?? productsPath.pathString
            events.emit(
                .init(
                    kind: .completed,
                    success: true,
                    productsPath: publishedProductsPath))
        }
    }

    private func requiredSelection(
        _ request: NucleusSwiftPMDriverRequest
    ) throws -> String {
        guard let selection = request.selection, !selection.isEmpty else {
            throw StringError("\(request.operation.rawValue) requires a selection")
        }
        return selection
    }

    private func requiredTestOptions(
        _ request: NucleusSwiftPMDriverRequest
    ) throws -> NucleusSwiftPMDriverRequest.TestOptions {
        guard let test = request.test else {
            throw StringError("test requires test options")
        }
        return test
    }
}

public enum NucleusSwiftPMDriver {
    public static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 5 || arguments.count == 6,
                arguments[1] == "--request-path",
                arguments[3] == "--events-path",
                arguments.count == 5 || arguments[5] == "--export-products"
            else {
                throw StringError(
                    "usage: swift-nucleus-driver --request-path <path> --events-path <path> [--export-products]"
                )
            }
            let request = try JSONDecoder().decode(
                NucleusSwiftPMDriverRequest.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let events = try NucleusDriverEventWriter(path: arguments[4])
            do {
                try await NucleusDriverContext.$current.withValue(
                    .init(request: request, events: events)
                ) {
                    var command = NucleusDriverCommand()
                    command.globalOptions = try nucleusGlobalOptions(for: request)
                    try await command.run()
                }
            } catch {
                events.emit(
                    .init(kind: .completed, message: String(describing: error), success: false))
                throw error
            }
        } catch {
            fputs("nucleus SwiftPM driver failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
