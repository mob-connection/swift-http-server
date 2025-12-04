//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import HTTPTypes

/// A protocol that defines the contract for handling HTTP server requests.
///
/// ``HTTPServerRequestHandler`` provides a structured way to process incoming HTTP requests
/// and generate appropriate responses. Conforming types implement the
/// ``handle(request:requestContext:requestBodyAndTrailers:responseSender:)`` method, which is
/// called by the HTTP server for each incoming request. The handler is responsible for reading
/// the request body, processing the request, and sending a response.
///
/// This protocol fully supports bidirectional streaming HTTP request handling, including
/// optional request and response trailers.
///
/// # Example
///
/// ```swift
/// struct EchoHandler<
///     ConcludingRequestReader: ConcludingAsyncReader<RequestReader, HTTPFields?> & ~Copyable,
///     RequestReader: AsyncReader<UInt8, any Error> & ~Copyable,
///     ConcludingResponseWriter: ConcludingAsyncWriter<RequestWriter, HTTPFields?> & ~Copyable,
///     RequestWriter: AsyncWriter<UInt8, any Error> & ~Copyable
/// >: HTTPServerRequestHandler {
///     func handle(
///         request: HTTPRequest,
///         requestContext: HTTPRequestContext,
///         requestBodyAndTrailers: consuming sending ConcludingRequestReader,
///         responseSender: consuming sending HTTPResponseSender<ConcludingResponseWriter>
///     ) async throws {
///         var responseSender: HTTPResponseSender<ConcludingResponseWriter>? = responseSender
///         _ = try await requestBodyAndTrailers.consumeAndConclude { reader in
///             var reader: RequestReader? = reader
///             let responseBodyAndTrailers = try await responseSender.take()!.send(
///                 .init(status: .ok)
///             )
///             try await responseBodyAndTrailers.produceAndConclude { writer in
///                 var writer = writer
///                 try await reader.take()!.forEach { span in
///                     try await writer.write(span)
///                 }
///                 return ((), nil)
///             }
///         }
///     }
/// }
/// ```
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol HTTPServerRequestHandler<RequestReader, ResponseWriter>: Sendable {
    /// The ``ConcludingAsyncReader`` to use when reading requests. ``ConcludingAsyncReader/FinalElement``
    /// must be an optional `HTTPFields`, and ``ConcludingAsyncReader/Underlying`` must use `Span<UInt8>` as its
    /// `ReadElement`.
    associatedtype RequestReader: ConcludingAsyncReader & ~Copyable & SendableMetatype
    where RequestReader.Underlying.ReadElement == Span<UInt8>,
          RequestReader.FinalElement == HTTPFields?

    /// The ``ConcludingAsyncWriter`` to use when writing responses. ``ConcludingAsyncWriter/FinalElement``
    /// must be an optional `HTTPFields`, and ``ConcludingAsyncWriter/Underlying`` must use `Span<UInt8>` as its
    /// `WriteElement`.
    associatedtype ResponseWriter: ConcludingAsyncWriter & ~Copyable & SendableMetatype
    where ResponseWriter.Underlying.WriteElement == Span<UInt8>,
          ResponseWriter.FinalElement == HTTPFields?

    /// Handles an incoming HTTP request and generates a response.
    ///
    /// This method is called by the HTTP server for each incoming client request. Implementations should:
    /// 1. Examine the request headers in the `request` parameter
    /// 2. Read the request body data from the `RequestReader` as needed
    /// 3. Process the request and prepare a response
    /// 4. Optionally call ``HTTPResponseSender/sendInformational(_:)`` as needed
    /// 4. Call the ``HTTPResponseSender/send(_:)`` with an appropriate HTTP response
    /// 5. Write the response body data to the returned `ResponseWriter`
    ///
    /// - Parameters:
    ///   - request: The HTTP request headers and metadata.
    ///   - requestContext: A ``HTTPRequestContext``.
    ///   - requestBodyAndTrailers: A reader for accessing the request body data and trailing headers.
    ///     This follows the `ConcludingAsyncReader` pattern, allowing for incremental reading of request body data
    ///     and concluding with any trailer fields sent at the end of the request.
    ///   - responseSender: An ``HTTPResponseSender`` that takes an HTTP response and returns a writer for the
    ///     response body. The returned writer allows for the incremental writing of the response body, and supports trailers.
    ///
    /// - Throws: Any error encountered during request processing or response generation.
    func handle(
        request: HTTPRequest,
        requestContext: HTTPRequestContext,
        requestBodyAndTrailers: consuming sending RequestReader,
        responseSender: consuming sending HTTPResponseSender<ResponseWriter>
    ) async throws
}
