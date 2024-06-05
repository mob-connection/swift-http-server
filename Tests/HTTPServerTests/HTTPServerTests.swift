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

import AsyncAlgorithms
import AsyncHTTPClient
import Atomics
import HTTPServer
import HTTPTypes
import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
import ServiceLifecycle
import XCTest

class HTTPServerTests: XCTestCase {
    static let eventLoopGroup: EventLoopGroup = {
        #if os(iOS)
        NIOTSEventLoopGroup.singleton
        #else
        MultiThreadedEventLoopGroup.singleton
        #endif
    }()

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testConnect() async throws {
        try await testServer(
            responder: helloResponder,
            serverBuilder: .http1(),
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let response = try await client.execute(.get, path: "/")
            XCTAssertEqual(String(buffer: response.body), "Hello")
        }
    }

    func testMultipleRequests() async throws {
        try await testServer(
            responder: helloResponder,
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            for _ in 0..<10 {
                let response = try await client.execute(.post, path: "/", body: ByteBuffer(string: "Hello"))
                XCTAssertEqual(String(buffer: response.body), "Hello")
            }
        }
    }

    func testConsumeBody() async throws {
        try await testServer(
            responder: { request, _ in
                do {
                    let buffer = try await request.body.collect(upTo: .max)
                    return Response(status: .ok, body: .init(byteBuffer: buffer))
                } catch {
                    return Response(status: .contentTooLarge)
                }
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 1_140_000)
            let response = try await client.post("/", body: buffer)
            let body = try XCTUnwrap(response.body)
            XCTAssertEqual(body, buffer)
        }
    }

    func testWriteBody() async throws {
        try await testServer(
            responder: { _, _ in
                let buffer = self.randomBuffer(size: 1_140_000)
                return Response(status: .ok, body: .init(byteBuffer: buffer))
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let response = try await client.get("/")
            let body = try XCTUnwrap(response.body)
            XCTAssertEqual(body.readableBytes, 1_140_000)
        }
    }

    func testStreamBody() async throws {
        try await testServer(
            responder: { request, _ in
                return Response(status: .ok, body: .init(asyncSequence: request.body))
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 1_140_000)
            let response = try await client.post("/", body: buffer)
            let body = try XCTUnwrap(response.body)
            XCTAssertEqual(body, buffer)
        }
    }

    func testStreamBodyWriteSlow() async throws {
        try await testServer(
            responder: { request, _ in
                return Response(status: .ok, body: .init(asyncSequence: request.body.delayed()))
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 1_140_000)
            let response = try await client.post("/", body: buffer)
            let body = try XCTUnwrap(response.body)
            XCTAssertEqual(body, buffer)
        }
    }

    func testStreamBodySlowStream() async throws {
        /// channel handler that delays the sending of data
        class SlowInputChannelHandler: ChannelOutboundHandler, RemovableChannelHandler {
            public typealias OutboundIn = Never
            public typealias OutboundOut = HTTPResponsePart

            func read(context: ChannelHandlerContext) {
                let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.eventLoop.scheduleTask(in: .milliseconds(Int64.random(in: 5..<50))) {
                    loopBoundContext.value.read()
                }
            }
        }
        try await testServer(
            responder: { request, _ in
                return Response(status: .ok, body: .init(asyncSequence: request.body.delayed()))
            },
            serverBuilder: .http1(additionalChannelHandlers: [SlowInputChannelHandler()]),
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 1_140_000)
            let response = try await client.post("/", body: buffer)
            let body = try XCTUnwrap(response.body)
            XCTAssertEqual(body, buffer)
        }
    }

    func testChannelHandlerErrorPropagation() async throws {
        struct HandlerError: Error {}
        class CreateErrorHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPRequestPart

            var seen: Bool = false
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if case .body = self.unwrapInboundIn(data) {
                    context.fireErrorCaught(HandlerError())
                }
                context.fireChannelRead(data)
            }
        }
        try await testServer(
            responder: { request, _ in
                do {
                    _ = try await request.body.collect(upTo: .max)
                    return Response(status: .ok)
                } catch is HandlerError {
                    return Response(status: .unavailableForLegalReasons)
                } catch {
                    return Response(status: .contentTooLarge)
                }
            },
            serverBuilder: .http1(additionalChannelHandlers: [CreateErrorHandler()]),
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 32)
            let response = try await client.post("/", body: buffer)
            XCTAssertEqual(response.status, .unavailableForLegalReasons)
        }
    }

    func testDropRequestBody() async throws {
        try await testServer(
            responder: { _, _ in
                // ignore request body
                return Response(status: .accepted)
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            let buffer = self.randomBuffer(size: 16384)
            let response = try await client.post("/", body: buffer)
            XCTAssertEqual(response.status, .accepted)
            let response2 = try await client.post("/", body: buffer)
            XCTAssertEqual(response2.status, .accepted)
        }
    }

    func testReadIdleHandler() async throws {
        /// Channel Handler for serializing request header and data
        final class HTTPServerIncompleteRequest: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPRequestPart
            typealias InboundOut = HTTPRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    break
                default:
                    context.fireChannelRead(data)
                }
            }
        }
        try await testServer(
            responder: { request, _ in
                do {
                    _ = try await request.body.collect(upTo: .max)
                    return .init(status: .ok)
                } catch {
                    return .init(status: .contentTooLarge)
                }
            },
            serverBuilder: .http1(additionalChannelHandlers: [HTTPServerIncompleteRequest(), IdleStateHandler(readTimeout: .seconds(1))]),
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { client in
            try await withTimeout(.seconds(5)) {
                do {
                    _ = try await client.get("/", headers: [.connection: "keep-alive"])
                    XCTFail("Should not get here")
                } catch let error as HTTPClientError where error == .remoteConnectionClosed {
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
    func testChildChannelGracefulShutdown() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()

        try await testHTTP1Server(
            responder: { request, _ in
                continuation.yield()
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    return Response(status: .ok, body: .init(asyncSequence: request.body.delayed()))
                } catch {
                    return Response(status: .serviceUnavailable)
                }
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { server, client in
            try await withTimeout(.seconds(5)) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            let response = try await client.get("/")
                            XCTAssertEqual(response.status, .ok)
                        } catch {
                            XCTFail("Error: \(error)")
                        }
                    }
                    await stream.first { _ in true }
                    try await server.shutdownGracefully()
                    try await group.waitForAll()
                }
            }
        }
    }

    func testIdleChildChannelGracefulShutdown() async throws {
        try await testHTTP1Server(
            responder: { request, _ in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    return Response(status: .ok, body: .init(asyncSequence: request.body.delayed()))
                } catch {
                    return Response(status: .serviceUnavailable)
                }
            },
            configuration: .init(address: .hostname(port: 0)),
            eventLoopGroup: Self.eventLoopGroup,
            logger: Logger(label: "Hummingbird")
        ) { server, client in
            try await withTimeout(.seconds(5)) {
                let response = try await client.get("/")
                XCTAssertEqual(response.status, .ok)
                try await server.shutdownGracefully()
            }
        }
    }
}

struct DelayAsyncSequence<CoreSequence: AsyncSequence>: AsyncSequence {
    typealias Element = CoreSequence.Element
    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: CoreSequence.AsyncIterator

        mutating func next() async throws -> Element? {
            try await Task.sleep(for: .milliseconds(Int.random(in: 10..<100)))
            return try await self.iterator.next()
        }
    }

    let seq: CoreSequence

    func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.seq.makeAsyncIterator())
    }
}

extension AsyncSequence {
    func delayed() -> DelayAsyncSequence<Self> {
        return .init(seq: self)
    }
}
