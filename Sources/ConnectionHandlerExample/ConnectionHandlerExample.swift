//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import BasicContainers
import Crypto
import ExampleSupport
import Foundation
import Instrumentation
import Logging
import NIOHTTPServer
import X509

@main
@available(anyAppleOS 26.0, *)
struct ConnectionHandlerExample {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        InstrumentationSystem.bootstrap(LogTracer())
        let rootLogger: Logger = {
            var logger = Logger(label: "ConnectionHandlerExample")
            logger.logLevel = .trace
            return logger
        }()

        let privateKey = P256.Signing.PrivateKey()
        let server = NIOHTTPServer(
            logger: rootLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12346),
                supportedHTTPVersions: [.http1_1, .http2(config: .init())],
                transportSecurity: .tls(
                    credentials: .inMemory(
                        certificateChain: [
                            try Certificate(
                                version: .v3,
                                serialNumber: .init(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
                                publicKey: .init(privateKey.publicKey),
                                notValidBefore: Date.now.addingTimeInterval(-60),
                                notValidAfter: Date.now.addingTimeInterval(60 * 60),
                                issuer: DistinguishedName(),
                                subject: DistinguishedName(),
                                signatureAlgorithm: .ecdsaWithSHA256,
                                extensions: .init(),
                                issuerPrivateKey: Certificate.PrivateKey(privateKey)
                            )
                        ],
                        privateKey: Certificate.PrivateKey(privateKey)
                    )
                )
            )
        )

        // A connection handler runs once per accepted connection and drives the
        // request loop via `connection.handleRequests`. Both the connection
        // handler and the request handler are inline closures.
        try await server.serve { connection, context in
            let connectionLogger: Logger = {
                var logger = rootLogger
                let peer = context.remoteAddress.map { "\($0)" } ?? "unknown"
                logger[metadataKey: "peer"] = .string(peer)
                logger[metadataKey: "http"] = .string("\(context.httpVersion)")
                return logger
            }()
            connectionLogger.info("connection accepted")
            defer { connectionLogger.info("connection closed") }

            try await connection.handleRequests { request, _, _, responseSender in
                connectionLogger.info("request received: \(request.path ?? "")")
                var body = UniqueArray<UInt8>(copying: "Well, hello!".utf8)
                try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
            }
        }
    }
}
