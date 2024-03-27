//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import HTTPServer
import HTTPTypes
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPTypesHTTP1
import NIOPosix
import NIOSSL
import ServiceLifecycle
import XCTest

public enum TestErrors: Error {
    case timeout
}

/// Basic responder that just returns "Hello" in body
@Sendable public func helloResponder(to request: Request, channel: Channel) async -> Response {
    let responseBody = channel.allocator.buffer(string: "Hello")
    return Response(status: .ok, body: .init(byteBuffer: responseBody))
}

struct TestClient {
    typealias Configuration = HTTPClient.Configuration

    struct Response: Sendable {
        public let head: HTTPResponse
        /// response status
        public var status: HTTPResponse.Status { self.head.status }
        /// response headers
        public var headers: HTTPFields { self.head.headerFields }
        /// response body
        public let body: ByteBuffer
    }

    let httpClient: HTTPClient
    let url: String

    init(host: String, port: Int, configuration: Configuration) {
        self.url = "http://\(host):\(port)"
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    }

    func execute(_ method: HTTPRequest.Method, path: String, headers: HTTPFields = [:], body: ByteBuffer? = nil) async throws -> Response {
        var request = HTTPClientRequest(url: self.url + path)
        request.method = .init(method)
        request.headers = .init(headers)
        request.body = body.map { .bytes($0) }
        let response = try await httpClient.execute(request, timeout: .seconds(15))
        let head: HTTPResponseHead = .init(version: response.version, status: response.status, headers: response.headers)
        return try await .init(
            head: .init(head), 
            body: response.body.collect(upTo: .max)
        )
    }

    func get(_ path: String, headers: HTTPFields = [:], body: ByteBuffer? = nil) async throws -> Response {
        try await execute(.get, path: path, headers: headers, body: body)
    }

    func post(_ path: String, headers: HTTPFields = [:], body: ByteBuffer? = nil) async throws -> Response {
        try await execute(.post, path: path, headers: headers, body: body)
    }

    func shutdown() async throws {
        try await self.httpClient.shutdown()
    }
}

/// Helper function for testing a server
public func testServer<ChildChannel: ServerChildChannel, Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    httpChannelSetup: HTTPChannelBuilder<ChildChannel>,
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    logger: Logger,
    _ test: @escaping @Sendable (Server<ChildChannel>, Int) async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Void.self) { group in
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let server = try Server(
            childChannelSetup: httpChannelSetup.build(responder),
            configuration: configuration,
            onServerRunning: { continuation.yield($0.localAddress!.port!) },
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [server],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )
        group.addTask {
            try await serviceGroup.run()
        }
        let port = await stream.first(where: { _ in true })!
        let value = try await test(server, port)
        await serviceGroup.triggerGracefulShutdown()
        return value
    }
}

/// Helper function for test a server
///
/// Creates test client, runs test function abd ensures everything is
/// shutdown correctly
func testServer<ChildChannel: ServerChildChannel, Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    httpChannelSetup: HTTPChannelBuilder<ChildChannel>,
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    logger: Logger,
    clientConfiguration: TestClient.Configuration = .init(),
    _ test: @escaping @Sendable (Server<ChildChannel>, TestClient) async throws -> Value
) async throws -> Value {
    try await testServer(
        responder: responder,
        httpChannelSetup: httpChannelSetup,
        configuration: configuration,
        eventLoopGroup: eventLoopGroup,
        logger: logger
    ) { (server: Server<ChildChannel>, port: Int) in
        let client = TestClient(
            host: "localhost",
            port: port,
            configuration: clientConfiguration
        )
        let value = try await test(server, client)
        try await client.shutdown()
        return value
    }
}

func testServer<Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    httpChannelSetup: HTTPChannelBuilder<some ServerChildChannel> = .http1(),
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    logger: Logger,
    clientConfiguration: TestClient.Configuration = .init(),
    _ test: @escaping @Sendable (TestClient) async throws -> Value
) async throws -> Value {
    try await testServer(
        responder: responder,
        httpChannelSetup: httpChannelSetup,
        configuration: configuration,
        eventLoopGroup: eventLoopGroup,
        logger: logger,
        clientConfiguration: clientConfiguration
    ) { _, client in
        try await test(client)
    }
}

/// Run process with a timeout
/// - Parameters:
///   - timeout: Amount of time before timeout error is thrown
///   - process: Process to run
public func withTimeout(_ timeout: TimeAmount, _ process: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await Task.sleep(nanoseconds: numericCast(timeout.nanoseconds))
            throw TestErrors.timeout
        }
        group.addTask {
            try await process()
        }
        try await group.next()
        group.cancelAll()
    }
}
