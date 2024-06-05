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
func testServer<Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    serverBuilder: HTTPServerBuilder = .http1(),
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    clientConfiguration: TestClient.Configuration = .init(),
    logger: Logger,
    _ test: @escaping @Sendable (TestClient) async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Void.self) { group in
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let server = try serverBuilder.buildServer(
            configuration: configuration, 
            eventLoopGroup: eventLoopGroup, 
            logger: logger, 
            responder: responder, 
            onServerRunning: { continuation.yield($0.localAddress!.port!) }
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
        let client = TestClient(
            host: "localhost",
            port: port,
            configuration: clientConfiguration
        )
        do {
            let value = try await test(client)
            try await client.shutdown()
            await serviceGroup.triggerGracefulShutdown()
            return value
        } catch {
            try await client.shutdown()
            await serviceGroup.triggerGracefulShutdown()
            throw error
        }
    }
}

/// Helper function for testing a HTTP1 server which takes a closure that includes the server
/// as a parameter
func testHTTP1Server<Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    clientConfiguration: TestClient.Configuration = .init(),
    logger: Logger,
    _ test: @escaping @Sendable (Server<HTTP1Channel>, TestClient) async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Void.self) { group in
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let server = Server<HTTP1Channel>(
            childChannelSetup: HTTP1Channel(responder: responder), 
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
        let client = TestClient(
            host: "localhost",
            port: port,
            configuration: clientConfiguration
        )
        do {
            let value = try await test(server, client)
            try await client.shutdown()
            await serviceGroup.triggerGracefulShutdown()
            return value
        } catch {
            try await client.shutdown()
            await serviceGroup.triggerGracefulShutdown()
            throw error
        }
    }
}

/// Helper function for test a server
///
/// Creates test client, runs test function abd ensures everything is
/// shutdown correctly
/*func testServer<Value: Sendable>(
    responder: @escaping HTTPChannelHandler.Responder,
    serverBuilder: HTTPServerBuilder = .http1(),
    configuration: ServerConfiguration,
    eventLoopGroup: EventLoopGroup,
    logger: Logger,
    clientConfiguration: TestClient.Configuration = .init(),
    _ test: @escaping @Sendable (TestClient) async throws -> Value
) async throws -> Value {
    try await _testServer(
        responder: responder,
        serverBuilder: serverBuilder,
        configuration: configuration,
        eventLoopGroup: eventLoopGroup,
        logger: logger
    ) {  (server: any Service, port: Int) in
        let client = TestClient(
            host: "localhost",
            port: port,
            configuration: clientConfiguration
        )
        let value = try await test(client)
        try await client.shutdown()
        return value
    }
}*/

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
