//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OTel open source project
//
// Copyright (c) 2025 the Swift OTel project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !OTLPHTTP
// Empty when above trait(s) are disabled.
#else
public import protocol SwiftProtobuf.Message
public import struct Logging.Logger

public protocol OTLPHTTPExporterProtocol: Sendable {
  init(configuration: OTel.Configuration.OTLPExporterConfiguration, logger: Logger) throws
  func send<Request: Message, Response: Message>(_ proto: Request) async throws -> Response
  func run() async throws
  func forceFlush() async throws
  func shutdown() async
}
#endif
