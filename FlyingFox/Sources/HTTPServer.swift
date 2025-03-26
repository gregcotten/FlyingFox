//
//  HTTPServer.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import FlyingSocks
import Foundation
#if canImport(WinSDK)
import WinSDK.WinSock2
#endif

public final actor HTTPServer {

    private let config: Configuration
    private var handlers: RoutedHTTPHandler

    init(config: Configuration, handler: RoutedHTTPHandler) {
        self.config = config
        self.handlers = Self.makeRootHandler(to: handler)
    }

    public init(config: Configuration, handler: (any HTTPHandler)? = nil) {
        self.init(config: config, handler: HTTPServer.makeRootHandler(to: handler))
    }

    public init(address: some SocketAddress,
                timeout: TimeInterval = 15,
                pool: some AsyncSocketPool = defaultPool(),
                logger: any Logging = defaultLogger(),
                handler: (any HTTPHandler)? = nil) {
        self.config = Configuration(
            address: address,
            timeout: timeout,
            pool: pool,
            logger: logger
        )
        self.handlers = Self.makeRootHandler(to: handler)
    }

    public var listeningAddress: Socket.Address? {
        try? state?.socket.sockname()
    }

    public func appendRoute(_ route: HTTPRoute, to handler: some HTTPHandler) {
        handlers.appendRoute(route, to: handler)
    }

    public func appendRoute(_ route: HTTPRoute, handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse) {
        handlers.appendRoute(route, handler: handler)
    }

    public func appendRoute<each P: HTTPRouteParameterValue>(
        _ route: HTTPRoute,
        handler: @Sendable @escaping (HTTPRequest, repeat each P) async throws -> HTTPResponse
    ) {
        handlers.appendRoute(route, handler: handler)
    }

    public func appendRoute<each P: HTTPRouteParameterValue>(
        _ route: HTTPRoute,
        handler: @Sendable @escaping (repeat each P) async throws -> HTTPResponse
    ) {
        handlers.appendRoute(route, handler: handler)
    }

    public func run() async throws {
        guard state == nil else {
            logger.logCritical("server error: already started")
            throw SocketError.unsupportedAddress
        }
        defer { state = nil }
        do {
            let socket = try await preparePoolAndSocket()
            let task = Task { try await start(on: socket, pool: config.pool) }
            state = (socket: socket, task: task)
            try await task.getValue(cancelling: .whenParentIsCancelled)
        } catch {
            logger.logCritical("server error: \(error.localizedDescription)")
            if let state = self.state {
                try? state.socket.close()
            }
            throw error
        }
    }

    @available(*, deprecated, renamed: "run")
    public func start() async throws {
        try await run()
    }

    func preparePoolAndSocket() async throws -> Socket {
        do {
            try await config.pool.prepare()
            return try makeSocketAndListen()
        } catch {
            logger.logCritical("server error: \(error.localizedDescription)")
            throw error
        }
    }

    var waiting = [Continuation.ID: Continuation]()
    private(set) var state: (socket: Socket, task: Task<Void, any Error>)? {
        didSet { isListeningDidUpdate(from: oldValue != nil ) }
    }

    private var logger: any Logging { config.logger }

    /// Stops the server by closing the listening socket and waiting for all connections to disconnect.
    /// - Parameter timeout: Seconds to allow for connections to close before server task is cancelled.
    public func stop(timeout: TimeInterval = 0) async {
        guard let (socket, task) = state else { return }
        state = nil
        try? socket.close()
        for connection in connections {
            await connection.complete()
        }
        try? await task.getValue(cancelling: .afterTimeout(seconds: timeout))
    }

    func makeSocketAndListen() throws -> Socket {
        let socket = try Socket(domain: Int32(type(of: config.address).family))

        #if canImport(WinSDK)
        if config.address.family != AF_UNIX {
            try socket.setValue(true, for: .exclusiveLocalAddressReuse)
        }
        #else
        try socket.setValue(true, for: .localAddressReuse)
        #endif

        #if canImport(Darwin)
        try socket.setValue(true, for: .noSIGPIPE)
        #endif
        try socket.bind(to: config.address)
        try socket.listen()
        logger.logListening(on: socket)
        return socket
    }

    func start(on socket: Socket, pool: some AsyncSocketPool) async throws {
        let asyncSocket = try AsyncSocket(socket: socket, pool: pool)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pool.run()
            }
            group.addTask {
                try await self.listenForConnections(on: asyncSocket)
            }
            try await group.next()
        }
    }

    @TaskLocal static var preferConnectionsDiscarding = true

    private func listenForConnections(on socket: AsyncSocket) async throws {
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *), Self.preferConnectionsDiscarding {
            try await listenForConnectionsDiscarding(on: socket)
        } else {
            try await listenForConnectionsFallback(on: socket)
        }
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func listenForConnectionsDiscarding(on socket: AsyncSocket) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            for try await socket in socket.sockets {
                group.addTask {
                    await self.handleConnection(self.makeConnection(socket: socket))
                }
            }
        }
        throw SocketError.disconnected
    }

    @available(macOS, deprecated: 17.0, renamed: "listenForConnectionsDiscarding(on:)")
    @available(iOS, deprecated: 17.0, renamed: "listenForConnectionsDiscarding(on:)")
    @available(tvOS, deprecated: 17.0, renamed: "listenForConnectionsDiscarding(on:)")
    private func listenForConnectionsFallback(on socket: AsyncSocket) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await socket in socket.sockets {
                group.addTask {
                    await self.handleConnection(self.makeConnection(socket: socket))
                }
            }
        }
        throw SocketError.disconnected
    }

    private func makeConnection(socket: AsyncSocket) -> HTTPConnection {
        HTTPConnection(
            socket: socket,
            decoder: HTTPDecoder(sharedRequestBufferSize: config.sharedRequestBufferSize, sharedRequestReplaySize: config.sharedRequestReplaySize),
            logger: config.logger
        )
    }

    private(set) var connections: Set<HTTPConnection> = []

    private func handleConnection(_ connection: HTTPConnection) async {
        logger.logOpenConnection(connection)
        connections.insert(connection)
        do {
            for try await request in connection.requests {
                logger.logRequest(request, on: connection)
                let response = await handleRequest(request)
                try await request.bodySequence.flushIfNeeded()
                try await connection.sendResponse(response)
            }
        } catch {
            logger.logError(error, on: connection)
        }
        connections.remove(connection)
        try? connection.close()
        logger.logCloseConnection(connection)
    }

    func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        var response = await handleRequest(request, timeout: config.timeout)
        if request.shouldKeepAlive {
            response.headers[.connection] = request.headers[.connection]
        }
        return response
    }

    func handleRequest(_ request: HTTPRequest, timeout: TimeInterval) async -> HTTPResponse {
        do {
            return try await withThrowingTimeout(seconds: timeout) { [handlers] in
                try await handlers.handleRequest(request)
            }
        } catch is HTTPUnhandledError {
            logger.logError("unhandled request")
            return HTTPResponse(statusCode: .notFound)
        }
        catch {
            logger.logError("handler error: \(error.localizedDescription)")
            return HTTPResponse(statusCode: .internalServerError)
        }
    }

    private static func makeRootHandler(to handler: (any HTTPHandler)?) -> RoutedHTTPHandler {
        var root = RoutedHTTPHandler()
        if let handler = handler {
            root.appendRoute("*", to: handler)
        }
        return root
    }

    private static func makeRootHandler(to closure: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse) -> RoutedHTTPHandler {
        var root = RoutedHTTPHandler()
        root.appendRoute("*", to: ClosureHTTPHandler(closure))
        return root
    }

    public static func defaultPool(logger: some Logging = .disabled) -> some AsyncSocketPool {
#if canImport(Darwin)
        return .kQueue(logger: logger)
#elseif canImport(CSystemLinux)
        return .ePoll(logger: logger)
#else
        return .poll(logger: logger)
#endif
    }
}

public extension HTTPServer {

    init(port: UInt16,
         timeout: TimeInterval = 15,
         logger: any Logging = defaultLogger(),
         handler: (any HTTPHandler)? = nil) {
        let config = Configuration(
            port: port,
            timeout: timeout,
            logger: logger
        )
        self.init(config: config, handler: handler)
    }

    init(port: UInt16,
         timeout: TimeInterval = 15,
         logger: any Logging = defaultLogger(),
         handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse) {
        let config = Configuration(
            port: port,
            timeout: timeout,
            logger: logger
        )
        self.init(config: config, handler: Self.makeRootHandler(to: handler))
    }
}

public extension HTTPServer {

    func appendRoute(
        _ path: String,
        for methods: some Sequence<HTTPMethod>,
        to handler: some HTTPHandler
    ) {
        let route = HTTPRoute(methods: methods, path: path)
        handlers.appendRoute(route, to: handler)
    }

    func appendRoute(
        _ path: String,
        for methods: some Sequence<HTTPMethod>,
        handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse
    ) {
        let route = HTTPRoute(methods: methods, path: path)
        handlers.appendRoute(route, handler: handler)
    }
}

extension Logging {

    func logOpenConnection(_ connection: HTTPConnection) {
        logInfo("\(connection.identifer) open connection")
    }

    func logCloseConnection(_ connection: HTTPConnection) {
        logInfo("\(connection.identifer) close connection")
    }

    func logSwitchProtocol(_ connection: HTTPConnection, to protocol: String) {
        logInfo("\(connection.identifer) switching protocol to \(`protocol`)")
    }

    func logRequest(_ request: HTTPRequest, on connection: HTTPConnection) {
        logInfo("\(connection.identifer) request: \(request.method.rawValue) \(request.path)")
    }

    func logError(_ error: any Error, on connection: HTTPConnection) {
        logError("\(connection.identifer) error: \(error.localizedDescription)")
    }

    func logListening(on socket: Socket) {
        logInfo(Self.makeListening(on: try? socket.sockname()))
    }

    static func makeListening(on addr: Socket.Address?) -> String {
        var comps = ["starting server"]
        guard let addr = addr else {
            return comps.joined()
        }

        switch addr {
        case let .ip4(address, port: port):
            if address == "0.0.0.0" {
                comps.append("port: \(port)")
            } else {
                comps.append("\(address):\(port)")
            }
        case let .ip6(address, port: port):
            if address == "::" {
                comps.append("port: \(port)")
            } else {
                comps.append("\(address):\(port)")
            }
        case let .unix(path):
            comps.append("path: \(path)")
        }
        return comps.joined(separator: " ")
    }
}

private extension HTTPConnection {
    var identifer: String {
        "<\(hostname)>"
    }
}
