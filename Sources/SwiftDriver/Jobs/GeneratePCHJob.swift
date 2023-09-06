//===--------------- GeneratePCHJob.swift - Generate PCH Job ----===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct TSCBasic.RelativePath

extension Driver {
  mutating func addGeneratePCHFlags(commandLine: inout [Job.ArgTemplate], inputs: inout [TypedVirtualPath]) throws {
    commandLine.appendFlag("-frontend")

    try addCommonFrontendOptions(
      commandLine: &commandLine, inputs: &inputs, kind: .generatePCH, bridgingHeaderHandling: .parsed)

    try commandLine.appendLast(.indexStorePath, from: &parsedOptions)

    commandLine.appendFlag(.emitPch)
  }

  mutating func generatePCHJob(input: TypedVirtualPath, output: TypedVirtualPath) throws -> Job {
    var inputs = [TypedVirtualPath]()
    var outputs = [TypedVirtualPath]()

    var commandLine: [Job.ArgTemplate] = swiftCompilerPrefixArgs.map { Job.ArgTemplate.flag($0) }

    if try supportsBridgingHeaderPCHCommand() {
      try addExplicitPCHBuildArguments(inputs: &inputs, commandLine: &commandLine)
    } else {
      try addGeneratePCHFlags(commandLine: &commandLine, inputs: &inputs)
    }

    // TODO: Should this just be pch output with extension changed?
    if parsedOptions.hasArgument(.serializeDiagnostics), let outputDirectory = parsedOptions.getLastArgument(.pchOutputDir)?.asSingle {
      commandLine.appendFlag(.serializeDiagnosticsPath)
      let path: VirtualPath
      if let outputPath = try outputFileMap?.existingOutput(inputFile: input.fileHandle, outputType: .diagnostics) {
        path = VirtualPath.lookup(outputPath)
      } else if let modulePath = parsedOptions.getLastArgument(.emitModulePath) {
        // TODO: does this hash need to be persistent?
        let code = UInt(bitPattern: modulePath.asSingle.hashValue)
        let outputName = input.file.basenameWithoutExt + "-" + String(code, radix: 36)
        path = try VirtualPath(path: outputDirectory).appending(component: outputName.appendingFileTypeExtension(.diagnostics))
      } else {
        path =
          VirtualPath.createUniqueTemporaryFile(
            RelativePath(input.file.basenameWithoutExt.appendingFileTypeExtension(.diagnostics)))
      }
      commandLine.appendPath(path)
      outputs.append(.init(file: path.intern(), type: .diagnostics))
    }

    // New compute and add inputs and outputs.
    if parsedOptions.hasArgument(.pchOutputDir) &&
       !parsedOptions.contains(.driverExplicitModuleBuild) {
      try commandLine.appendLast(.pchOutputDir, from: &parsedOptions)
    } else {
      commandLine.appendFlag(.o)
      commandLine.appendPath(output.file)
    }
    outputs.append(output)

    inputs.append(input)
    try addPathArgument(input.file, to: &commandLine, remap: true)

    return Job(
      moduleName: moduleOutputInfo.name,
      kind: .generatePCH,
      tool: try toolchain.resolvedTool(.swiftCompiler),
      commandLine: commandLine,
      displayInputs: [],
      inputs: inputs,
      primaryInputs: [],
      outputs: outputs
    )
  }
}
