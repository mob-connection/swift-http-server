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

import Logging
import NIOCore
import ServiceLifecycle

/// HTTP server service
public struct HTTPServer: Service {
    let service: any Service

    ///  Initialize an HTTP server
    /// - Parameters:
    ///   - server: Server type (defaults to HTTP1 server)
    ///   - configuration: Configuration
    ///   - eventLoopGroup: EventLoopGroup used by server
    ///   - logger: Logger used by server
    ///   - responder: How the server should respond to a HTTP Request 
    ///   - onServerRunning: Called when the server is up and running
    public init(
        server: HTTPServerBuilder = .http1(),
        configuration: ServerConfiguration,
        eventLoopGroup: EventLoopGroup,
        logger: Logger,
        responder: @escaping HTTPChannelHandler.Responder,
        onServerRunning: (@Sendable (Channel) async -> Void)? = nil
    ) throws {
        self.service = try server.buildServer(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            responder: responder,
            onServerRunning: onServerRunning
        )
    }

    /// Run the service
    public func run() async throws {
        try await self.service.run()
    }
}