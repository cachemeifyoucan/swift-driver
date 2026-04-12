//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import class Foundation.Thread
import struct Foundation.TimeInterval

/// Retries `body` up to `maxAttempts` times with exponential backoff.
///
/// If all attempts fail, the error from the last attempt is thrown.
///
/// - Parameters:
///   - maxAttempts: Maximum number of times to attempt `body` (default: 5).
///   - initialDelay: The delay before the first retry, in seconds (default: 0.1).
///   - body: The throwing operation to attempt.
func withExponentialBackoff<T>(
  maxAttempts: Int = 5,
  initialDelay: TimeInterval = 0.1,
  _ body: () throws -> T
) throws -> T {
  // Add a bit randomness to avoid lock stepped back off.
  var delay = initialDelay * Double.random(in: 0.9...1.1)
  var lastError: Error?

  for _ in 0..<maxAttempts {
    do {
      return try body()
    } catch {
      lastError = error
      Thread.sleep(forTimeInterval: delay)
      delay *= 2
    }
  }
  throw lastError!
}
