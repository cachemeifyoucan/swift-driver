//===--------------- ExplicitDependencyBuildPlanner.swift ---------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct TSCBasic.SHA256
import struct TSCBasic.AbsolutePath

import struct Foundation.Data
import class Foundation.JSONEncoder

/// Details about an external target, including the path to its .swiftmodule file
/// and whether it is a framework.
public struct ExternalTargetModuleDetails {
  public init(path: AbsolutePath, isFramework: Bool) {
    self.path = path
    self.isFramework = isFramework
  }
  let path: AbsolutePath
  let isFramework: Bool
}

public typealias ExternalTargetModuleDetailsMap = [ModuleDependencyId: ExternalTargetModuleDetails]

/// In Explicit Module Build mode, this planner is responsible for generating and providing
/// build jobs for all module dependencies and providing compile command options
/// that specify said explicit module dependencies.
@_spi(Testing) public struct ExplicitDependencyBuildPlanner {
  /// The module dependency graph.
  private let dependencyGraph: InterModuleDependencyGraph

  /// A set of direct and transitive dependencies for every module in the dependency graph
  private let reachabilityMap: [ModuleDependencyId : Set<ModuleDependencyId>]

  /// The toolchain to be used for frontend job generation.
  private let toolchain: Toolchain

  /// Whether we are using the integrated driver via libSwiftDriver shared lib
  private let integratedDriver: Bool
  private let mainModuleName: String?
  private let enableCAS: Bool
  private let swiftScanOracle: InterModuleDependencyOracle

  /// Clang PCM names contain a hash of the command-line arguments that were used to build them.
  /// We avoid re-running the hash computation with the use of this cache
  private var hashedModuleNameCache: [String: String] = [:]

  /// Does this compile support `.explicitInterfaceModuleBuild`
  private var supportsExplicitInterfaceBuild: Bool

  public init(dependencyGraph: InterModuleDependencyGraph,
              toolchain: Toolchain,
              dependencyOracle: InterModuleDependencyOracle,
              integratedDriver: Bool = true,
              supportsExplicitInterfaceBuild: Bool = false,
              enableCAS: Bool = false) throws {
    self.dependencyGraph = dependencyGraph
    self.toolchain = toolchain
    self.swiftScanOracle = dependencyOracle
    self.integratedDriver = integratedDriver
    self.mainModuleName = dependencyGraph.mainModuleName
    self.reachabilityMap = try dependencyGraph.computeTransitiveClosure()
    self.supportsExplicitInterfaceBuild = supportsExplicitInterfaceBuild
    self.enableCAS = enableCAS
  }

  /// Generate build jobs for all dependencies of the main module.
  /// The main module itself is handled elsewhere in the driver.
  ///
  /// The main source of complexity in this procedure is versioning of Clang dependency PCMs.
  /// There exists a strict limitation that a compatible PCM must have the exact same target version
  /// with the loading module (either a Swift module or another PCM). This means that each PCM may
  /// have to be built multiple times, once for each unique (SDK, architecture, toolchain) tuple
  /// of some loading module.
  ///
  /// For example:
  ///   Main (target: 10.13) depends on ClangA, SwiftB, SwiftC, SwiftD, ClangD
  ///   SwiftB (target: 10.12) depends on ClangB, SwiftC
  ///   SwiftC (target: 10.11) depends on ClangC
  ///   SwiftD (target: 10.10) depends on ClangD
  /// (Clang{A,B,C,D} are leaf modules)
  /// If the task is to build `main`, the Clang modules in this example have the following "uses":
  ///   ClangA is used directly by Main.
  ///   ClangB is used directly by SwiftB and transitively by Main.
  ///   ClangC is used directly by SwiftC and transitively by Main and SwiftB.
  ///   ClangD is used directly by SwiftD and Main.
  /// Given the individual targets of the uses, the following versions of the Clang modules must
  /// be built:
  ///   ClangA: (10.13)
  ///   ClangB: (10.12, 10.13)
  ///   ClangC: (10.11, 10.12, 10.13)
  ///   ClangD: (10.10, 10.13)
  ///
  /// Due to this requirement, we generate jobs for main main module dependencies in two stages:
  /// 1. Generate jobs for all Swift modules, accumulating, for each Clang dependency, the depending Swift
  /// module's target version (PCM Args).
  /// 2. Generate jobs for all Clang modules, now that we have each module's set of PCM versions it must be
  /// built against.
  public mutating func generateExplicitModuleDependenciesBuildJobs() throws -> [Job] {
    let mainModuleId: ModuleDependencyId = .swift(dependencyGraph.mainModuleName)
    guard let mainModuleDependencies = reachabilityMap[mainModuleId] else {
      fatalError("Expected reachability information for the main module.")
    }
    // A collection of PCM Args that Clang modules must be built against
    var clangPCMSetMap: [ModuleDependencyId : Set<[String]>] = [:]
    let swiftDependenciesJobs =
      try generateSwiftDependenciesBuildJobs(for: mainModuleDependencies,
                                             clangPCMSetMap: &clangPCMSetMap)
    // Also take into account the PCMArgs of the main module
    try updateClangPCMArgSetMap(for: mainModuleId, clangPCMSetMap: &clangPCMSetMap)

    // Generate build jobs for all Clang modules
    let clangDependenciesJobs =
      try generateClangDependenciesBuildJobs(for: mainModuleDependencies,
                                             using: clangPCMSetMap)

    return swiftDependenciesJobs + clangDependenciesJobs
  }

  /// Generate a build job for each Swift module in the set of supplied `dependencies`
  private mutating func generateSwiftDependenciesBuildJobs(for dependencies: Set<ModuleDependencyId>,
                                                           clangPCMSetMap:
                                                            inout [ModuleDependencyId : Set<[String]>])
  throws -> [Job] {
    var jobs: [Job] = []
    let swiftDependencies = dependencies.filter {
      if case .swift(_) = $0 {
        return true
      }
      return false
    }
    for moduleId in swiftDependencies {
      let moduleInfo = try dependencyGraph.moduleInfo(of: moduleId)
      let pcmArgs = try dependencyGraph.swiftModulePCMArgs(of: moduleId)
      var inputs: [TypedVirtualPath] = []
      let outputs: [TypedVirtualPath] = [
        TypedVirtualPath(file: moduleInfo.modulePath.path, type: .swiftModule)
      ]
      var commandLine: [Job.ArgTemplate] = []
      // First, take the command line options provided in the dependency information
      let moduleDetails = try dependencyGraph.swiftModuleDetails(of: moduleId)
      moduleDetails.commandLine?.forEach { commandLine.appendFlags($0) }

      // Resolve all dependency module inputs for this Swift module
      try resolveExplicitModuleDependencies(moduleId: moduleId, pcmArgs: pcmArgs,
                                            inputs: &inputs,
                                            commandLine: &commandLine)

      // Update the clangPCMSetMap for each Clang dependency of this module
      try updateClangPCMArgSetMap(for: moduleId, clangPCMSetMap: &clangPCMSetMap)

      // Build the .swiftinterfaces file using a list of command line options specified in the
      // `details` field.
      guard let moduleInterfacePath = moduleDetails.moduleInterfacePath else {
        throw Driver.Error.malformedModuleDependency(moduleId.moduleName,
                                                     "no `moduleInterfacePath` object")
      }
      inputs.append(TypedVirtualPath(file: moduleInterfacePath.path,
                                     type: .swiftInterface))

      // Add precompiled module candidates, if present
      if let compiledCandidateList = moduleDetails.compiledModuleCandidates {
        for compiledCandidate in compiledCandidateList {
          inputs.append(TypedVirtualPath(file: compiledCandidate.path,
                                         type: .swiftModule))
        }
      }

      jobs.append(Job(
        moduleName: moduleId.moduleName,
        kind: .compileModuleFromInterface,
        tool: try toolchain.resolvedTool(.swiftCompiler),
        commandLine: commandLine,
        inputs: inputs,
        primaryInputs: [],
        outputs: outputs
      ))
    }
    return jobs
  }

  /// Generate a build job for each Clang module in the set of supplied `dependencies`. Once per each required
  /// PCMArgSet as queried from the supplied `clangPCMSetMap`
  private mutating func generateClangDependenciesBuildJobs(for dependencies: Set<ModuleDependencyId>,
                                                           using clangPCMSetMap:
                                                            [ModuleDependencyId : Set<[String]>])
  throws -> [Job] {
    var jobs: [Job] = []
    let clangDependencies = dependencies.filter {
      if case .clang(_) = $0 {
        return true
      }
      return false
    }
    for moduleId in clangDependencies {
      guard let pcmArgSet = clangPCMSetMap[moduleId] else {
        fatalError("Expected PCM Argument Set for module: \(moduleId.moduleName)")
      }
      let moduleInfo = try dependencyGraph.moduleInfo(of: moduleId)
      // Generate a distinct job for each required set of PCM Arguments for this module
      for pcmArgs in pcmArgSet {
        var inputs: [TypedVirtualPath] = []
        var outputs: [TypedVirtualPath] = []
        var commandLine: [Job.ArgTemplate] = []

        // First, take the command line options provided in the dependency information
        let moduleDetails = try dependencyGraph.clangModuleDetails(of: moduleId)
        moduleDetails.commandLine.forEach { commandLine.appendFlags($0) }
        
        // Add the `-target` option as inherited from the dependent Swift module's PCM args
        pcmArgs.forEach { commandLine.appendFlags($0) }

        // Resolve all dependency module inputs for this Clang module
        try resolveExplicitModuleDependencies(moduleId: moduleId, pcmArgs: pcmArgs,
                                              inputs: &inputs,
                                              commandLine: &commandLine)

        let moduleMapPath = moduleDetails.moduleMapPath.path
        let modulePCMPath = moduleInfo.modulePath
        outputs.append(TypedVirtualPath(file: modulePCMPath.path, type: .pcm))

        // The only required input is the .modulemap for this module.
        // Command line options in the dependency scanner output will include the
        // required modulemap, so here we must only add it to the list of inputs.
        inputs.append(TypedVirtualPath(file: moduleMapPath,
                                       type: .clangModuleMap))

        jobs.append(Job(
          moduleName: moduleId.moduleName,
          kind: .generatePCM,
          tool: try toolchain.resolvedTool(.swiftCompiler),
          commandLine: commandLine,
          inputs: inputs,
          primaryInputs: [],
          outputs: outputs
        ))
      }
    }
    return jobs
  }

  /// For the specified module, update the given command line flags and inputs
  /// to use explicitly-built module dependencies.
  private mutating func resolveExplicitModuleDependencies(moduleId: ModuleDependencyId, pcmArgs: [String],
                                                          inputs: inout [TypedVirtualPath],
                                                          commandLine: inout [Job.ArgTemplate]) throws {
    // Prohibit the frontend from implicitly building textual modules into binary modules.
    var swiftDependencyArtifacts: [SwiftModuleArtifactInfo] = []
    var clangDependencyArtifacts: [ClangModuleArtifactInfo] = []
    try addModuleDependencies(of: moduleId, pcmArgs: pcmArgs,
                              clangDependencyArtifacts: &clangDependencyArtifacts,
                              swiftDependencyArtifacts: &swiftDependencyArtifacts)

    // Each individual module binary is still an "input" to ensure the build system gets the
    // order correctly.
    for dependencyModule in swiftDependencyArtifacts {
      inputs.append(TypedVirtualPath(file: dependencyModule.modulePath.path,
                                     type: .swiftModule))
    }

    // Clang module dependencies are specified on the command line explicitly
    for moduleArtifactInfo in clangDependencyArtifacts {
      let clangModulePath =
        TypedVirtualPath(file: moduleArtifactInfo.clangModulePath.path,
                         type: .pcm)
      let clangModuleMapPath =
        TypedVirtualPath(file: moduleArtifactInfo.clangModuleMapPath.path,
                         type: .clangModuleMap)
      inputs.append(clangModulePath)
      inputs.append(clangModuleMapPath)
    }

    // Swift Main Module dependencies are passed encoded in a JSON file as described by
    // SwiftModuleArtifactInfo
    if moduleId.moduleName == mainModuleName {
      if enableCAS {
        let dependencyFile =
          try serializeModuleDependenciesToCAS(for: moduleId,
                                               swiftDependencyArtifacts: swiftDependencyArtifacts,
                                               clangDependencyArtifacts: clangDependencyArtifacts)
        commandLine.appendFlag("-explicit-swift-module-map-file")
        commandLine.appendFlag(dependencyFile)
      } else {
        let dependencyFile =
          try serializeModuleDependencies(for: moduleId,
                                          swiftDependencyArtifacts: swiftDependencyArtifacts,
                                          clangDependencyArtifacts: clangDependencyArtifacts)
        commandLine.appendFlag("-explicit-swift-module-map-file")
        commandLine.appendPath(dependencyFile)
        inputs.append(TypedVirtualPath(file: dependencyFile.intern(),
                                       type: .jsonSwiftArtifacts))
      }
    }
  }

  private mutating func addModuleDependency(of moduleId: ModuleDependencyId,
                                            dependencyId: ModuleDependencyId, pcmArgs: [String],
                                            clangDependencyArtifacts: inout [ClangModuleArtifactInfo],
                                            swiftDependencyArtifacts: inout [SwiftModuleArtifactInfo]
  ) throws {
    switch dependencyId {
      case .swift:
        let dependencyInfo = try dependencyGraph.moduleInfo(of: dependencyId)
        let swiftModulePath: TypedVirtualPath
        let isFramework: Bool
        swiftModulePath = .init(file: dependencyInfo.modulePath.path,
                                type: .swiftModule)
        let swiftModuleDetails = try dependencyGraph.swiftModuleDetails(of: dependencyId)
        isFramework = swiftModuleDetails.isFramework ?? false
        // Accumulate the required information about this dependency
        // TODO: add .swiftdoc and .swiftsourceinfo for this module.
        swiftDependencyArtifacts.append(
          SwiftModuleArtifactInfo(name: dependencyId.moduleName,
                                  modulePath: TextualVirtualPath(path: swiftModulePath.fileHandle),
                                  isFramework: isFramework,
                                  moduleCacheKey: swiftModuleDetails.moduleCacheKey))
      case .clang:
        let dependencyInfo = try dependencyGraph.moduleInfo(of: dependencyId)
        let dependencyClangModuleDetails =
          try dependencyGraph.clangModuleDetails(of: dependencyId)
        // Accumulate the required information about this dependency
        clangDependencyArtifacts.append(
          ClangModuleArtifactInfo(name: dependencyId.moduleName,
                                  modulePath: TextualVirtualPath(path: dependencyInfo.modulePath.path),
                                  moduleMapPath: dependencyClangModuleDetails.moduleMapPath,
                                  moduleCacheKey: dependencyClangModuleDetails.moduleCacheKey))
      case .swiftPrebuiltExternal:
        let prebuiltModuleDetails = try dependencyGraph.swiftPrebuiltDetails(of: dependencyId)
        let compiledModulePath = prebuiltModuleDetails.compiledModulePath
        let isFramework = prebuiltModuleDetails.isFramework ?? false
        let swiftModulePath: TypedVirtualPath =
          .init(file: compiledModulePath.path, type: .swiftModule)
        // Accumulate the required information about this dependency
        // TODO: add .swiftdoc and .swiftsourceinfo for this module.
        swiftDependencyArtifacts.append(
          SwiftModuleArtifactInfo(name: dependencyId.moduleName,
                                  modulePath: TextualVirtualPath(path: swiftModulePath.fileHandle),
                                  isFramework: isFramework,
                                  moduleCacheKey: prebuiltModuleDetails.moduleCacheKey))
      case .swiftPlaceholder:
        fatalError("Unresolved placeholder dependencies at planning stage: \(dependencyId) of \(moduleId)")
    }
  }

  /// Add a specific module dependency as an input and a corresponding command
  /// line flag.
  private mutating func addModuleDependencies(of moduleId: ModuleDependencyId, pcmArgs: [String],
                                              clangDependencyArtifacts: inout [ClangModuleArtifactInfo],
                                              swiftDependencyArtifacts: inout [SwiftModuleArtifactInfo]
  ) throws {
    guard let moduleDependencies = reachabilityMap[moduleId] else {
      fatalError("Expected reachability information for the module: \(moduleId.moduleName).")
    }
    for dependencyId in moduleDependencies {
      try addModuleDependency(of: moduleId, dependencyId: dependencyId, pcmArgs: pcmArgs,
                              clangDependencyArtifacts: &clangDependencyArtifacts,
                              swiftDependencyArtifacts: &swiftDependencyArtifacts)
    }
  }

  private func updateClangPCMArgSetMap(for moduleId: ModuleDependencyId,
                                       clangPCMSetMap: inout [ModuleDependencyId : Set<[String]>])
  throws {
    guard let moduleDependencies = reachabilityMap[moduleId] else {
      fatalError("Expected reachability information for the module: \(moduleId.moduleName).")
    }
    let pcmArgs = try dependencyGraph.swiftModulePCMArgs(of: moduleId)
    for dependencyId in moduleDependencies {
      guard case .clang(_) = dependencyId else {
        continue
      }
      if clangPCMSetMap[dependencyId] != nil {
        clangPCMSetMap[dependencyId]!.insert(pcmArgs)
      } else {
        clangPCMSetMap[dependencyId] = [pcmArgs]
      }
    }
  }

  /// Resolve all module dependencies of the main module and add them to the lists of
  /// inputs and command line flags.
  public mutating func resolveMainModuleDependencies(inputs: inout [TypedVirtualPath],
                                                     commandLine: inout [Job.ArgTemplate],
                                                     bridgingHeaderCacheKey: String?) throws {
    let mainModuleId: ModuleDependencyId = .swift(dependencyGraph.mainModuleName)
    commandLine.appendFlags("-disable-implicit-swift-modules",
                            "-Xcc", "-fno-implicit-modules",
                            "-Xcc", "-fno-implicit-module-maps")
    if let bridgingHeaderKey = bridgingHeaderCacheKey {
      commandLine.appendFlag("-bridging-header-pch-key")
      commandLine.appendFlag(bridgingHeaderKey)
    }
    try resolveExplicitModuleDependencies(moduleId: mainModuleId,
                                          pcmArgs:
                                            try dependencyGraph.swiftModulePCMArgs(of: mainModuleId),
                                          inputs: &inputs,
                                          commandLine: &commandLine)
  }

  /// Resolve all module dependencies of the main module and add them to the lists of
  /// inputs and command line flags.
  public mutating func resolveBridgingHeaderDependencies(inputs: inout [TypedVirtualPath],
                                                         commandLine: inout [Job.ArgTemplate]) throws {
    let mainModuleId: ModuleDependencyId = .swift(dependencyGraph.mainModuleName)
    // Prohibit the frontend from implicitly building textual modules into binary modules.
    commandLine.appendFlags("-disable-implicit-swift-modules",
                            "-Xcc", "-fno-implicit-modules",
                            "-Xcc", "-fno-implicit-module-maps")

    var swiftDependencyArtifacts: [SwiftModuleArtifactInfo] = []
    var clangDependencyArtifacts: [ClangModuleArtifactInfo] = []
    let mainModuleDetails = try dependencyGraph.swiftModuleDetails(of: mainModuleId)

    var addedDependencies: Set<ModuleDependencyId> = []
    var dependenciesWorklist = mainModuleDetails.bridgingHeaderDependencies ?? []

    while !dependenciesWorklist.isEmpty {
      guard let bridgingHeaderDepID = dependenciesWorklist.popLast() else {
        break
      }
      guard !addedDependencies.contains(bridgingHeaderDepID) else {
        continue
      }
      addedDependencies.insert(bridgingHeaderDepID)
      try addModuleDependency(of: mainModuleId, dependencyId: bridgingHeaderDepID, pcmArgs: [],
                              clangDependencyArtifacts: &clangDependencyArtifacts,
                              swiftDependencyArtifacts: &swiftDependencyArtifacts)
      try addModuleDependencies(of: bridgingHeaderDepID, pcmArgs: [],
                                clangDependencyArtifacts: &clangDependencyArtifacts,
                                swiftDependencyArtifacts: &swiftDependencyArtifacts)
      let depInfo = try dependencyGraph.moduleInfo(of: bridgingHeaderDepID)
      dependenciesWorklist.append(contentsOf: depInfo.directDependencies ?? [])
    }

    // Clang module dependencies are specified on the command line explicitly
    for moduleArtifactInfo in clangDependencyArtifacts {
      let clangModulePath =
        TypedVirtualPath(file: moduleArtifactInfo.clangModulePath.path,
                         type: .pcm)
      let clangModuleMapPath =
        TypedVirtualPath(file: moduleArtifactInfo.clangModuleMapPath.path,
                         type: .clangModuleMap)
      inputs.append(clangModulePath)
      inputs.append(clangModuleMapPath)
    }

    if enableCAS {
      let dependencyFile =
      try serializeModuleDependenciesToCAS(for: mainModuleId,
                                           swiftDependencyArtifacts: swiftDependencyArtifacts,
                                           clangDependencyArtifacts: clangDependencyArtifacts)
      commandLine.appendFlag("-explicit-swift-module-map-file")
      commandLine.appendFlag(dependencyFile)
    } else {
      let dependencyFile =
      try serializeModuleDependencies(for: mainModuleId,
                                      swiftDependencyArtifacts: swiftDependencyArtifacts,
                                      clangDependencyArtifacts: clangDependencyArtifacts)
      commandLine.appendFlag("-explicit-swift-module-map-file")
      commandLine.appendPath(dependencyFile)
      inputs.append(TypedVirtualPath(file: dependencyFile.intern(),
                                     type: .jsonSwiftArtifacts))
    }
  }

  /// Store the output file artifacts for a given module in a JSON file, return the file's path.
  private func serializeModuleDependencies(for moduleId: ModuleDependencyId,
                                           swiftDependencyArtifacts: [SwiftModuleArtifactInfo],
                                           clangDependencyArtifacts: [ClangModuleArtifactInfo]
  ) throws -> VirtualPath {
    let allDependencyArtifacts: [ModuleDependencyArtifactInfo] =
      swiftDependencyArtifacts.map {ModuleDependencyArtifactInfo.swift($0)} +
      clangDependencyArtifacts.map {ModuleDependencyArtifactInfo.clang($0)}
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let contents = try encoder.encode(allDependencyArtifacts)
    return VirtualPath.createUniqueTemporaryFileWithKnownContents(.init("\(moduleId.moduleName)-dependencies.json"), contents)
  }

  private func serializeModuleDependenciesToCAS(for moduleId: ModuleDependencyId,
                                           swiftDependencyArtifacts: [SwiftModuleArtifactInfo],
                                           clangDependencyArtifacts: [ClangModuleArtifactInfo]
  ) throws -> String {
    let allDependencyArtifacts: [ModuleDependencyArtifactInfo] =
      swiftDependencyArtifacts.map {ModuleDependencyArtifactInfo.swift($0)} +
      clangDependencyArtifacts.map {ModuleDependencyArtifactInfo.clang($0)}
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let contents = try encoder.encode(allDependencyArtifacts)
    return try swiftScanOracle.store(data: contents)
  }

  private func getPCMHashParts(pcmArgs: [String], contextHash: String) -> [String] {
    var results: [String] = []
    results.append(contextHash)
    results.append(contentsOf: pcmArgs)
    if integratedDriver {
      return results
    }

    // We need this to enable explicit modules in the driver-as-executable mode. For instance,
    // we have two Swift targets A and B, where A depends on X.pcm which in turn depends on Y.pcm,
    // and B only depends on Y.pcm. In the driver-as-executable mode, the build system isn't aware
    // of the shared dependency of Y.pcm so it will be generated multiple times. If all these Y.pcm
    // share the same name, X.pcm may fail to be loaded because its dependency Y.pcm may have a
    // changed mod time.
    // We only differentiate these PCM names in the non-integrated mode due to the lacking of
    // inter-module planning.
    results.append(mainModuleName!)
    return results
  }
}

/// Encapsulates some of the common queries of the ExplicitDependencyBuildPlanner with error-checking
/// on the dependency graph's structure.
@_spi(Testing) public extension InterModuleDependencyGraph {
  func moduleInfo(of moduleId: ModuleDependencyId) throws -> ModuleInfo {
    guard let moduleInfo = modules[moduleId] else {
      throw Driver.Error.missingModuleDependency(moduleId.moduleName)
    }
    return moduleInfo
  }

  func swiftModuleDetails(of moduleId: ModuleDependencyId) throws -> SwiftModuleDetails {
    guard case .swift(let swiftModuleDetails) = try moduleInfo(of: moduleId).details else {
      throw Driver.Error.malformedModuleDependency(moduleId.moduleName, "no Swift `details` object")
    }
    return swiftModuleDetails
  }

  func swiftPrebuiltDetails(of moduleId: ModuleDependencyId)
  throws -> SwiftPrebuiltExternalModuleDetails {
    guard case .swiftPrebuiltExternal(let prebuiltModuleDetails) =
            try moduleInfo(of: moduleId).details else {
      throw Driver.Error.malformedModuleDependency(moduleId.moduleName,
                                                   "no SwiftPrebuiltExternal `details` object")
    }
    return prebuiltModuleDetails
  }

  func clangModuleDetails(of moduleId: ModuleDependencyId) throws -> ClangModuleDetails {
    guard case .clang(let clangModuleDetails) = try moduleInfo(of: moduleId).details else {
      throw Driver.Error.malformedModuleDependency(moduleId.moduleName, "no Clang `details` object")
    }
    return clangModuleDetails
  }

  func swiftModulePCMArgs(of moduleId: ModuleDependencyId) throws -> [String] {
    let moduleDetails = try swiftModuleDetails(of: moduleId)
    return moduleDetails.extraPcmArgs
  }
}

// InterModuleDependencyGraph printing, useful for debugging
internal extension InterModuleDependencyGraph {
  func prettyPrintString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let contents = try encoder.encode(self)
    return String(data: contents, encoding: .utf8)!
  }
}
