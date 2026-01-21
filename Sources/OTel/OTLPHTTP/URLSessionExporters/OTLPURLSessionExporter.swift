//
//  OTLPURLSessionExporter.swift
//  swift-otel
//
//  Created by Joe Diragi on 1/21/26.
//

#if !OTLPHTTPURLSession
// Empty when above trait(s) are disabled.
#else

import Logging
import ServiceLifecycle
import SwiftProtobuf

#if canImport(FoundationNetworking)
import class FoundationNetworking.URLSession
import struct FoundationNetworking.URLRequest
import class FoundationNetworking.URLResponse
import class FoundationNetworking.HTTPURLResponse
#else
import class Foundation.URLSession
import struct Foundation.URLRequest
import class Foundation.URLResponse
import class Foundation.HTTPURLResponse
#endif

#if canImport(FoundationEssentials)
import class FoundationEssentials.FileManager
import struct FoundationEssentials.URL
import struct FoundationEssentials.Data
#else
import class Foundation.FileManager
import struct Foundation.URL
import struct Foundation.Data
#endif

final class OTLPHTTPExporter<Request: Message, Response: Message>: Sendable {
    private let logger: Logger
    let configuration: OTel.Configuration.OTLPExporterConfiguration
    let session: URLSession

    init(configuration: OTel.Configuration.OTLPExporterConfiguration, logger: Logger, urlSession: URLSession = .shared) throws {
        self.logger = logger
        self.configuration = configuration
        self.session = .shared
    }

    func run() async throws {
        // No background work needed, but we'll keep the run method running until its cancelled.
        try await gracefulShutdown()
    }

    func send(_ proto: Request) async throws -> Response {
        // https://opentelemetry.io/docs/specs/otlp/#otlphttp-request
        var request = URLRequest(url: .init(string: self.configuration.endpoint)!)
        request.httpMethod = "POST"
        for (name, value) in configuration.headers {
            request.addValue(value, forHTTPHeaderField: name)
        }
        switch self.configuration.protocol.backing {
        case .httpProtobuf:
            // https://opentelemetry.io/docs/specs/otlp/#binary-protobuf-encoding
            let body: ByteBufferWrapper = try proto.serializedBytes()
            request.httpBody = body.asData()
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        case .httpJSON:
            // https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding
            var encodingOptions = JSONEncodingOptions()
            encodingOptions.alwaysPrintInt64sAsNumbers = false
            encodingOptions.alwaysPrintEnumsAsInts = true
            encodingOptions.preserveProtoFieldNames = false
            let body: ByteBufferWrapper = try proto.jsonUTF8Bytes(options: encodingOptions)
            request.httpBody = body.asData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .grpc:
            preconditionFailure("unreachable")
        }

        // https://opentelemetry.io/docs/specs/otel/protocol/exporter/#user-agent
        request.setValue("OTel-OTLP-Exporter-Swift/\(OTelLibrary.version)", forHTTPHeaderField: "User-Agent")
        // https://opentelemetry.io/docs/specs/otlp/#otlphttp-connection
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        // https://opentelemetry.io/docs/specs/otlp/#otlphttp-response
        let (data, response) = try await self.session.execute(
            request,
            timeout: self.configuration.timeout,
            logger: self.logger,
            retryPolicy: .otel
        )

        guard 200 ... 299 ~= response.status else {
            // https://opentelemetry.io/docs/specs/otlp/#failures
            // TODO: Apparently failures include Protobuf-encoded GRPC Status -- we could try and include it here.
            throw OTLPHTTPExporterError.requestFailed(response.status)
        }

        // https://opentelemetry.io/docs/specs/otlp/#full-success-1
        let body = data
        
        // Disregard parameters in the content-type string (i.e., "application/json; charset=utf-8")
        let contentType = response.valueFor(header: "Content-Type")?.components(separatedBy: ";").first
        let responseMessage = switch contentType {
        case "application/x-protobuf":
            try Response(serializedBytes: ByteBufferWrapper(backing: body))
        case "application/json":
            try Response(jsonUTF8Bytes: ByteBufferWrapper(backing: body))
        case .some(let content):
            throw OTLPHTTPExporterError.responseHasUnsupportedContentType(content)
        case .none:
            if response.status == 204 {
                Response()
            } else {
                throw OTLPHTTPExporterError.responseHasMissingContentType
            }
        }
        return responseMessage
    }

    func forceFlush() async throws {
        // This exporter is a "push exporter" and so the OTel spec says that force flush should do nothing.
    }

    func shutdown() async {
        self.session.finishTasksAndInvalidate()
    }
}

extension URLSession {
    func execute<Clock: _Concurrency.Clock>(
        _ request: URLRequest,
        timeout: Clock.Duration,
        logger: Logger? = nil,
        clock: Clock = .continuous,
        retryPolicy: RetryPolicy
    ) async throws -> (Data, URLResponse) where Clock.Duration == Duration {
        if var logger {
            logger[metadataKey: "attempts"] = "\(retryPolicy.attempts)"
            logger[metadataKey: "max_attempts"] = "\(retryPolicy.maxAttempts)"
        }
        logger?.debug("Making request.")
        var retryPolicy = retryPolicy
        var request = request
        request.timeoutInterval = .init(timeout.components.seconds)
        let (data, response) = try await self.data(for: request)
        switch retryPolicy.shouldRetry(response: response) {
        case .doNotRetry:
            logger?.debug("Returning response.", metadata: ["status_code": "\(response.status)"])
            return (data, response)
        case .retryAfter(let delay):
            logger?.debug("Retrying request.", metadata: ["status_code": "\(response.status)"])
            try await _Concurrency.Task.sleep(for: delay, clock: clock)
            return try await self.execute(
                request,
                timeout: timeout,
                logger: logger,
                clock: clock,
                retryPolicy: retryPolicy
            )
        }
    }
}

extension URLResponse {
    var status: Int {
        (self as! HTTPURLResponse).statusCode
    }

    func valueFor(header: String) -> String? {
        (self as! HTTPURLResponse).value(forHTTPHeaderField: header)
    }
}

extension RetryPolicy {
    /// A policy for use with the OTLP/HTTP exporter, following guidance from the spec.
    ///
    /// - See: [](https://opentelemetry.io/docs/specs/otlp/#retryable-response-codes)
    /// - See: [](https://opentelemetry.io/docs/specs/otlp/#otlphttp-throttling)
    static let otel = Self { response in
        switch response.status {
        case 429, 502, 503, 504:
            if let specificBackoff = response.valueFor(header: "Retry-After").flatMap(Int.init) {
                .retryWithSpecificBackoff(.seconds(specificBackoff))
            } else {
                .retryWithBackoff
            }
        default: .doNotRetry
        }
    }
}

#endif
