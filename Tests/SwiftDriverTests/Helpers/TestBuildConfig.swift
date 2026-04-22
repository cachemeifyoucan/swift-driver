//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
@_spi(Testing) import SwiftDriver
import TSCBasic
import Testing

// MARK: - Build Configuration

/// Set `SWIFT_DRIVER_TEST_VERBOSE=1` in the environment to print diagnostics
/// and debug messages to stderr when debugging tests.
let verboseTestOutput = ProcessEnv.block["SWIFT_DRIVER_TEST_VERBOSE"] != nil

enum TestBuildConfig: CaseIterable, CustomStringConvertible, Sendable {
  case implicitModule
  case explicitModule
  case cachingBuild
  case cachingPrefixMapped

  var description: String {
    switch self {
    case .implicitModule: "implicit"
    case .explicitModule: "explicit"
    case .cachingBuild: "caching"
    case .cachingPrefixMapped: "cachingPrefixMapped"
    }
  }

  var isExplicitModuleBuild: Bool { self != .implicitModule }
  var requiresCaching: Bool { self == .cachingBuild || self == .cachingPrefixMapped }

  static var explicitConfigs: [TestBuildConfig] {
    allCases.filter(\.isExplicitModuleBuild)
  }

  /// Filter configs to only those supported by the current environment.
  static func available(_ configs: [TestBuildConfig]) -> [TestBuildConfig] {
    configs.filter { !$0.requiresCaching || cachingFeatureSupported }
  }

  /// All explicit module build configs that are available.
  static var availableExplicitConfigs: [TestBuildConfig] {
    available(explicitConfigs)
  }

  /// Explicit-only (no caching) configs.
  static var explicitOnlyConfigs: [TestBuildConfig] {
    available([.explicitModule])
  }

  /// Caching configs only.
  static var cachingConfigs: [TestBuildConfig] {
    available([.cachingBuild, .cachingPrefixMapped])
  }

  /// Not prefix mapped explicit build.
  static var explicitNonPrefixed: [TestBuildConfig] {
    available([.explicitModule, .cachingBuild])
  }
}

extension TestBuildConfig: CustomTestStringConvertible {
  var testDescription: String { description }
}

// MARK: Testing Traits

extension Trait where Self == Testing.ConditionTrait {
  /// Skip on Windows platforms.
  package static func skipWindows(_ comment: Comment? = nil) -> Self {
    #if os(Windows)
    disabled(comment ?? "This test cannot run on windows")
    #else
    enabled(if: true)
    #endif
  }

  /// Skip on Linux platforms.
  package static func skipLinux(_ comment: Comment? = nil) -> Self {
    #if canImport(Linux)
    disabled(comment ?? "This test cannot run on Linux")
    #else
    enabled(if: true)
    #endif
  }

  /// Requires ObjC Runtime to run.
  package static func requireObjCRuntime(_ comment: Comment? = nil) -> Self {
    #if _runtime(_ObjC)
    enabled(if: true)
    #else
    disabled(comment ?? "This test requires ObjC Runtime")
    #endif
  }

}

// MARK: - Feature availability

let sdkArgumentsAvailable: Bool = {
  do {
    return try Driver.sdkArgumentsForTesting() != nil
  } catch {
    return false
  }
}()

let cachingFeatureSupported: Bool = {
  guard let driver = try? Driver(args: ["swiftc"]) else { return false }
  return driver.isFeatureSupported(.compilation_caching)
}()
