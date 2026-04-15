//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

internal func executableName(_ name: String) -> String {
#if os(Windows)
  if name.count > 4, name.suffix(from: name.index(name.endIndex, offsetBy: -4)) == ".exe" {
    return name
  }
  return "\(name).exe"
#else
  return name
#endif
}

@_spi(Testing) public func sharedLibraryName(_ name: String) -> String {
#if canImport(Darwin)
  return "lib" + name + ".dylib"
#elseif os(Windows)
  return name + ".dll"
#else
  return "lib" + name + ".so"
#endif
}

// FIXME: This can be subtly wrong, we should rather
// try to get the client to provide this info or move to a better
// path convention for where we keep compiler support libraries
internal var compilerHostSupportLibraryOSComponent : String {
#if canImport(Darwin)
  return "macosx"
#elseif os(Windows)
  return "windows"
#else
  return "linux"
#endif
}
