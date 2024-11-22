//
//  AsyncSocketTests.swift
//  FlyingFox
//
//  Created by Simon Whitty on 22/02/2022.
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

@testable import FlyingSocks
import Foundation
import Testing

struct AsyncSocketTests {

    @Test
    func socketReadsByte_WhenAvailable() async throws {
        let (s1, s2) = try await AsyncSocket.makePair()

        async let d2 = s2.read()
        try await s1.write(Data([10]))
        let v2 = try await d2
        #expect(v2 == 10)

        try s1.close()
        try s2.close()
    }

    @Test
    func socketReadsChunk_WhenAvailable() async throws {
        let (s1, s2) = try await AsyncSocket.makePair()

        async let d2 = s2.readString(length: 12)
        Task {
            try await s1.writeString("Fish & Chips")
        }

        let text = try await d2
        #expect(text == "Fish & Chips")
    }

    @Test
    func socketWrite_WaitsWhenBufferIsFull() async throws {
        let (s1, s2) = try await AsyncSocket.makePair()
        try s1.socket.setValue(1024, for: .sendBufferSize)

        let task = Task {
            try await s1.write(Data(repeating: 0x01, count: 8192))
        }

        _ = try await s2.read(bytes: 8192)
        try await task.value
    }

    @Test
    func socketReadByte_ThrowsDisconnected_WhenSocketIsClosed() async throws {
        let s1 = try await AsyncSocket.make()
        try s1.close()

        await #expect(throws: SocketError.self) {
            try await s1.read()
        }
    }

    @Test
    func socketRead0Byte_ReturnsEmptyArray() async throws {
        let s1 = try await AsyncSocket.make()

        let bytes = try await s1.read(bytes: 0)
        #expect(bytes == [])
    }

    @Test
    func socketReadByte_Throws_WhenSocketIsNotOpen() async throws {
        let s1 = try await AsyncSocket.make()

        await #expect(throws: SocketError.self) {
            try await s1.read()
        }
    }

    @Test
    func socketReadChunk_ThrowsDisconnected_WhenSocketIsClosed() async throws {
        let s1 = try await AsyncSocket.make()
        try s1.close()

        await #expect(throws: SocketError.self) {
            try await s1.read(bytes: 5)
        }
    }

    @Test
    func socketReadChunk_Throws_WhenSocketIsNotOpen() async throws {
        let s1 = try await AsyncSocket.make()

        await #expect(throws: SocketError.self) {
            try await s1.read(bytes: 5)
        }
    }

    @Test
    func socketBytesReadChunk_Throws_WhenSocketIsClosed() async throws {
        let s1 = try await AsyncSocket.make()
        try s1.close()

        let bytes = s1.bytes
        await #expect(throws: SocketError.self) {
            _ = try await bytes.nextBuffer(suggested: 1)
        }
    }

    @Test
    func socketBytesReadChunk_Throws_WhenSocketIsNotOpen() async throws {
        let s1 = try await AsyncSocket.make()

        let bytes = s1.bytes
        await #expect(throws: SocketError.self) {
            _ = try await bytes.nextBuffer(suggested: 1)
        }
    }

    @Test
    func socketWrite_ThrowsDisconnected_WhenSocketIsClosed() async throws {
        let s1 = try await AsyncSocket.make()
        try s1.close()

        await #expect(throws: SocketError.disconnected) {
            try await s1.writeString("Fish")
        }
    }

    @Test
    func socketWrite_Throws_WhenSocketIsNotConnected() async throws {
        let s1 = try await AsyncSocket.make()

        await #expect(throws: SocketError.self) {
            try await s1.writeString("Fish")
        }
    }

    @Test
    func socketAccept_Throws_WhenSocketIsClosed() async throws {
        let s1 = try await AsyncSocket.make()

        await #expect(throws: SocketError.self) {
            try await s1.accept()
        }
    }

    @Test
    func socket_Throws_WhenAlreadyCLosed() async throws {
        let s1 = try await AsyncSocket.make()

        try s1.close()
        #expect(throws: SocketError.self) {
            try s1.close()
        }
    }

    @Test
    func socketSequence_Ends_WhenDisconnected() async throws {
        let s1 = try AsyncSocket.makeListening(pool: DisconnectedPool())
        var sockets = s1.sockets
        #expect(
            try await sockets.next() == nil
        )
    }

    @Test
    func datagramSocketReceivesChunk_WhenAvailable() async throws {
        let (s1, s2, addr) = try await AsyncSocket.makeDatagramPair()

        async let d2: (any SocketAddress, [UInt8]) = s2.receive(atMost: 100)
        // TODO: calling send() on Darwin to an unconnected datagram domain
        // socket returns EISCONN
#if canImport(Darwin)
        try await s1.write("Swift".data(using: .utf8)!)
#else
        try await s1.send("Swift".data(using: .utf8)!, to: addr)
#endif
        let v2 = try await d2
        #expect(String(data: Data(v2.1), encoding: .utf8) == "Swift")

        try s1.close()
        try s2.close()
        try? Socket.unlink(addr)
    }

#if !canImport(WinSDK)
    @Test
    func datagramSocketReceivesMessageTupleAPI_WhenAvailable() async throws {
        let (s1, s2, addr) = try await AsyncSocket.makeDatagramPair()

        async let d2: AsyncSocket.Message = s2.receive(atMost: 100)
#if canImport(Darwin)
        try await s1.write("Swift".data(using: .utf8)!)
#else
        try await s1.send(message: "Swift".data(using: .utf8)!, to: addr, from: addr)
#endif
        let v2 = try await d2
        #expect(String(data: Data(v2.bytes), encoding: .utf8) == "Swift")

        try s1.close()
        try s2.close()
        try? Socket.unlink(addr)
    }
#endif

#if !canImport(WinSDK)
    @Test
    func datagramSocketReceivesMessageStructAPI_WhenAvailable() async throws {
        let (s1, s2, addr) = try await AsyncSocket.makeDatagramPair()
        let messageToSend = AsyncSocket.Message(
            peerAddress: addr,
            bytes: Array("Swift".data(using: .utf8)!),
            localAddress: addr
        )

        async let d2: AsyncSocket.Message = s2.receive(atMost: 100)
#if canImport(Darwin)
        try await s1.write("Swift".data(using: .utf8)!)
#else
        try await s1.send(message: messageToSend)
#endif
        let v2 = try await d2
        #expect(String(data: Data(v2.bytes), encoding: .utf8) == "Swift")

        try s1.close()
        try s2.close()
        try? Socket.unlink(addr)
    }
#endif

    @Test
    func testMessageSequence() async throws {
        let (socket, port) = try await AsyncSocket.makeLoopbackDatagram()
        var messages = socket.messages

        async let received = [messages.next(), messages.next()]

        let client = try await AsyncSocket.makeLoopbackDatagram().0
        try await client.sendString("Fish 🐡", to: .loopback(port: port))
        try await client.sendString("Chips 🍟", to: .loopback(port: port))

        #expect(
            try await received.compactMap { try $0?.payloadString } == [
                "Fish 🐡",
                "Chips 🍟"
            ]
        )
    }
}

extension AsyncSocket {

    static func make(domain: Int32 = AF_UNIX, type: SocketType = .stream) async throws -> AsyncSocket {
        try await make(pool: .client, domain: domain, type: type)
    }

    static func makeListening(pool: some AsyncSocketPool) throws -> AsyncSocket {
        let address = sockaddr_un.unix(path: #function)
        try? Socket.unlink(address)
        let socket = try Socket(domain: AF_UNIX, type: .stream)
        try socket.setValue(true, for: .localAddressReuse)
        try socket.bind(to: address)
        try socket.listen()
        return try AsyncSocket(socket: socket, pool: pool)
    }

    static func make(pool: some AsyncSocketPool,
                     domain: Int32 = AF_UNIX,
                     type: SocketType = .stream) throws -> AsyncSocket {
        let socket = try Socket(domain: domain, type: type)
        return try AsyncSocket(socket: socket, pool: pool)
    }

    static func makeLoopbackDatagram() async throws -> (AsyncSocket, port: UInt16) {
        let socket = try await AsyncSocket.make(domain: AF_INET6, type: .datagram)
        try socket.socket.bind(to: .loopback(port: 0))
        guard case let .ip6(_, port: port) = try socket.socket.sockname() else {
            fatalError()
        }
        return (socket, port)
    }

    static func makeDatagramPair() async throws -> (AsyncSocket, AsyncSocket, sockaddr_un) {
        let socketPair = try await makePair(pool: .client, type: .datagram)
        guard let endpoint = FileManager.default.makeTemporaryFile() else {
            throw SocketError.makeFailed("MakeTemporaryFile")
        }
        let addr = sockaddr_un.unix(path: endpoint.path)

        try socketPair.1.socket.bind(to: addr)
#if canImport(Darwin)
        try await socketPair.0.connect(to: addr)
#endif

        return (socketPair.0, socketPair.1, addr)
    }

    static func makePair() async throws -> (AsyncSocket, AsyncSocket) {
        try await makePair(pool: .client, type: .stream)
    }

    func writeString(_ string: String) async throws {
        try await write(string.data(using: .utf8)!)
    }

    func readString(length: Int) async throws -> String {
        let bytes = try await read(bytes: length)
        guard let string = String(data: Data(bytes), encoding: .utf8) else {
            throw SocketError.makeFailed("Read")
        }
        return string
    }

    func sendString(_ string: String, to address: some SocketAddress) async throws {
        try await send(string.data(using: .utf8)!, to:address)
    }
}

private extension AsyncSocket.Message {

    var payloadString: String {
        get throws {
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw SocketError.disconnected
            }
            return text
        }
    }
}

struct DisconnectedPool: AsyncSocketPool {

    func prepare() async throws { }

    func run() async throws { }

    func suspendSocket(_ socket: FlyingSocks.Socket, untilReadyFor events: FlyingSocks.Socket.Events) async throws {
        throw SocketError.disconnected
    }
}
