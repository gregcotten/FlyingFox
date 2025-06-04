//
//  FileHTTPHandler.swift
//  FlyingFox
//
//  Created by Simon Whitty on 14/02/2022.
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

public struct FileHTTPHandler: HTTPHandler {

    private(set) var path: URL?
    let contentType: String

    public init(path: URL, contentType: String) {
        self.path = path
        self.contentType = contentType
    }

    public init(named: String, in bundle: Bundle, contentType: String? = nil) {
        self.path = bundle.url(forResource: named, withExtension: nil)
        self.contentType = contentType ?? Self.makeContentType(for: named)
    }

    static func makeContentType(for filename: String) -> String {
        // TODO: UTTypeCreatePreferredIdentifierForTag / UTTypeCopyPreferredTagWithClass
        let pathExtension = (filename.lowercased() as NSString).pathExtension
        switch pathExtension {
        case "json":
            return "application/json"
        case "html", "htm":
            return "text/html"
        case "css":
            return "text/css"
        case "js", "javascript":
            return "application/javascript"
        case "png":
            return "image/png"
        case "jpeg", "jpg":
            return "image/jpeg"
        case "m4v", "mp4":
            return "video/mp4"
        case "pdf":
            return "application/pdf"
        case "svg":
            return "image/svg+xml"
        case "txt":
            return "text/plain"
        case "ico":
            return "image/x-icon"
        case "wasm":
            return "application/wasm"
        case "webp":
            return "image/webp"
        case "jp2":
            return "image/jp2"
        default:
            return "application/octet-stream"
        }
    }

    public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let path = path else {
            return HTTPResponse(statusCode: .notFound)
        }

        do {
            var headers: [HTTPHeader: String] = [
                .contentType: contentType,
                .acceptRanges: "bytes"
            ]

            let fileSize = try AsyncBufferedFileSequence.fileSize(at: path)

            if request.method == .HEAD {
                headers[.contentLength] = String(fileSize)
                return HTTPResponse(
                    statusCode: .ok,
                    headers: headers
                )
            }

            if let range = Self.makePartialRange(for: request.headers) {
                headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
                return try HTTPResponse(
                    statusCode: .partialContent,
                    headers: headers,
                    body: HTTPBodySequence(file: path, range: range.lowerBound..<range.upperBound + 1)
                )
            } else {
                return try HTTPResponse(
                    statusCode: .ok,
                    headers: headers,
                    body: HTTPBodySequence(file: path)
                )
            }
        } catch {
            return HTTPResponse(statusCode: .notFound)
        }
    }

    static func makePartialRange(for headers: [HTTPHeader: String]) -> ClosedRange<Int>? {
        guard let headerValue = headers[.range] else { return nil }
        let scanner = Scanner(string: headerValue)
        guard scanner.scanString("bytes") != nil,
              scanner.scanString("=") != nil,
              let start = scanner.scanInt(),
              scanner.scanString("-") != nil,
              let end = scanner.scanInt(),
              start <= end else {
            return nil
        }
        return start...end
    }
}
