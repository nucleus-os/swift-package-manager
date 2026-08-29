//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import PackageModel
import SPMBuildCore
import TSCBasic

/// The typed invocation surface used by Nucleus' out-of-process build driver.
///
/// This lives beside SwiftPM's option model so the driver never has to recreate
/// command-line arguments and feed them back through ArgumentParser. It is an
/// internal contract of the pinned Nucleus SwiftPM overlay, not a supported
/// upstream SwiftPM API.
public struct NucleusSwiftPMInvocationOptions: Sendable {
    public enum BuildSystem: String, Sendable {
        case native
        case swiftbuild
    }

    public enum Configuration: String, Sendable {
        case debug
        case release
    }

    public let packagePath: String
    public let scratchPath: String
    public let cachePath: String?
    public let swiftSDKsPath: String?
    public let buildSystem: BuildSystem
    public let configuration: Configuration
    public let jobs: UInt32
    public let debugInformationFormat: String?
    public let targetTriple: String?
    public let swiftSDK: String?
    public let toolsetPaths: [String]
    public let forceResolvedVersions: Bool
    public let sanitizer: String?
    public let traits: [String]
    public let swiftCompilerFlags: [String]
    public let cCompilerFlags: [String]
    public let cxxCompilerFlags: [String]
    public let linkerFlags: [String]

    public init(
        packagePath: String,
        scratchPath: String,
        cachePath: String? = nil,
        swiftSDKsPath: String? = nil,
        buildSystem: BuildSystem,
        configuration: Configuration,
        jobs: UInt32,
        debugInformationFormat: String? = nil,
        targetTriple: String? = nil,
        swiftSDK: String? = nil,
        toolsetPaths: [String] = [],
        forceResolvedVersions: Bool = false,
        sanitizer: String? = nil,
        traits: [String] = [],
        swiftCompilerFlags: [String] = [],
        cCompilerFlags: [String] = [],
        cxxCompilerFlags: [String] = [],
        linkerFlags: [String] = []
    ) {
        self.packagePath = packagePath
        self.scratchPath = scratchPath
        self.cachePath = cachePath
        self.swiftSDKsPath = swiftSDKsPath
        self.buildSystem = buildSystem
        self.configuration = configuration
        self.jobs = jobs
        self.debugInformationFormat = debugInformationFormat
        self.targetTriple = targetTriple
        self.swiftSDK = swiftSDK
        self.toolsetPaths = toolsetPaths
        self.forceResolvedVersions = forceResolvedVersions
        self.sanitizer = sanitizer
        self.traits = traits
        self.swiftCompilerFlags = swiftCompilerFlags
        self.cCompilerFlags = cCompilerFlags
        self.cxxCompilerFlags = cxxCompilerFlags
        self.linkerFlags = linkerFlags
    }
}

extension GlobalOptions {
    /// Build the option model the driver runs from, without a command line.
    ///
    /// An ArgumentParser property wrapper holds a declaration until parsing
    /// replaces it with a value, and reading one that still holds a declaration
    /// is a fatal configuration failure. `GlobalOptions()` leaves every group
    /// declared, and assigning through a wrapped property reads it first, so
    /// mutating a directly constructed value traps on the first assignment.
    ///
    /// Parsing an empty argument list is what materializes every declared
    /// default, which is exactly the state `swift build` with no arguments
    /// starts from. It reconstructs no command line: the request's fields are
    /// then assigned onto the typed model directly, and nothing about the
    /// request is ever rendered as an argument.
    public init(nucleus options: NucleusSwiftPMInvocationOptions) throws {
        self = try GlobalOptions.parse([])
        locations.packageDirectory = try AbsolutePath(validating: options.packagePath)
        locations._scratchDirectory = try AbsolutePath(validating: options.scratchPath)
        locations.cacheDirectory = try options.cachePath.map(AbsolutePath.init(validating:))
        locations.swiftSDKsDirectory = try options.swiftSDKsPath.map(AbsolutePath.init(validating:))
        locations.toolsetPaths = try options.toolsetPaths.map(AbsolutePath.init(validating:))
        resolver.forceResolvedVersions = options.forceResolvedVersions
        build.configuration =
            switch options.configuration {
            case .debug: .debug
            case .release: .release
            }
        build._buildSystem =
            switch options.buildSystem {
            case .native: .native
            case .swiftbuild: .swiftbuild
            }
        build.jobs = options.jobs
        build.debugInfoFormat = try options.debugInformationFormat.map {
            guard let value = BuildOptions.DebugInfoFormat(rawValue: $0) else {
                throw StringError("unknown debug information format '\($0)'")
            }
            return value
        }
        build.customCompileTriple = try options.targetTriple.map(Triple.init)
        build.swiftSDKSelector = options.swiftSDK
        build.sanitizers =
            try options.sanitizer.map {
                guard let value = Sanitizer(argument: $0) else {
                    throw StringError("unknown sanitizer '\($0)'")
                }
                return [value]
            } ?? []
        traits._enabledTraits =
            options.traits.isEmpty
            ? nil
            : options.traits.joined(separator: ",")
        build.swiftCompilerFlags = options.swiftCompilerFlags
        build.cCompilerFlags = options.cCompilerFlags
        build.cxxCompilerFlags = options.cxxCompilerFlags
        build.linkerFlags = options.linkerFlags
    }
}
