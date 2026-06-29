//
//  NetworkChannel.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 13.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import Foundation

enum NetworkChannelError : Error {
    case OpeningNonClosedChannel
    case CannotCreateStream (String)
    case CannotConnectToServer (String)
    case GetDataFromNonOpenChannel
    case SendingToNonOpenChannel
    case ReadError
    case WriteError
}

enum State {
    case closed
    case opening ((NetworkChannel) -> Void, (Error) -> Void)
    case firstStreamOpen ((NetworkChannel) -> Void, (Error) -> Void)
    case open
    case error
}

func ==(lhs: State, rhs: State) -> Bool {
    switch (lhs, rhs) {
        
    case (.closed, .closed): return true
    case (.opening(_, _), .opening(_, _)): return true
    case (.firstStreamOpen(_, _), .firstStreamOpen(_, _)): return true
    case (.open, .open): return true
    case (.error, .error): return true

    default: return false
        
    }
}

private struct Request {
    let length: Int
    let buffer: OpaquePointer
    
    let fulfill: (OpaquePointer) -> Void
    let reject: (Error) -> Void
}

private class ActiveRequest {
    let request: Request
    var bytesDone: Int
    var buffer: UnsafeMutablePointer<UInt8>
    private var isCompleted = false

    init(request: Request) {
        self.request = request
        self.bytesDone = 0
        self.buffer = UnsafeMutablePointer<UInt8>(request.buffer)
    }

    // Resume the underlying continuation at most once. A write completing
    // (writeNextChunk) and a stream error (.errorOccurred) can both target the
    // same request; resuming a checked continuation twice is a fatal
    // "SWIFT TASK CONTINUATION MISUSE".
    func fulfill(_ p: OpaquePointer) {
        guard !isCompleted else { return }
        isCompleted = true
        request.fulfill(p)
    }

    func reject(_ error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        request.reject(error)
    }
}

public class NetworkChannel : NSObject, StreamDelegate {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    
    var state: State = State.closed
    let server: String
    let port: Int

    private var writeRequestQueue: [Request] = []
    private var activeWriteRequest: ActiveRequest?
    
    private let inputBufferSize = 1024*32
    private var inputBufferPointer: UnsafeMutableRawPointer? = nil
    private var bytesInInputBuffer: Int
   
    private var inputBufferIndex: Int
    private let gotInputBuffer = PromisedQueue<(byteCount: Int, buffer: UnsafeMutableRawPointer)>("gotInputBuffer")
    
    init(server: String, port: Int) {
        self.server = server
        self.port = port
        self.activeWriteRequest = nil
        
        self.bytesInInputBuffer = 0
        self.inputBufferIndex = 0
    }
    
    func connect() async throws -> NetworkChannel {
        guard state == .closed else {
            throw NetworkChannelError.OpeningNonClosedChannel
        }

        Stream.getStreamsToHost(withName: server, port: port, inputStream: &inputStream, outputStream: &outputStream)

        guard let input = inputStream, let output = outputStream else {
            throw NetworkChannelError.CannotCreateStream("\(server):\(port)")
        }

        input.delegate = self
        output.delegate = self

        input.schedule(in: RunLoop.main, forMode: RunLoop.Mode.default)
        output.schedule(in: RunLoop.main, forMode: RunLoop.Mode.default)

        input.open()
        output.open()

        return try await withCheckedThrowingContinuation { cont in
            state = .opening({ channel in
                cont.resume(returning: channel)
            }, { error in
                cont.resume(throwing: error)
            })
        }
    }
    
    func disconnect() {
        state = .closed
        
        if let stream = inputStream {
            deinitStream(stream: stream)
            inputStream = nil
        }
        
        if let stream = outputStream {
            deinitStream(stream: stream)
            outputStream = nil
        }

        // Resume any pending/active write continuations so the tasks awaiting them
        // don't leak (continuation misuse / suspended forever).
        rejectAllPendingWrites(NetworkChannelError.WriteError)
    }

    /// Resume every pending and active write continuation with an error. Safe to
    /// call repeatedly: the active request resumes at most once (its own guard) and
    /// the queue is emptied, so a second call is a no-op.
    private func rejectAllPendingWrites(_ error: Error) {
        let active = activeWriteRequest
        activeWriteRequest = nil
        let pending = writeRequestQueue
        writeRequestQueue = []

        active?.reject(error)
        for request in pending {
            request.reject(error)
        }
    }

    /// Treat a mid-session stream failure (error or end-of-stream) as connection
    /// loss: stop the reader and fail all pending writes so every awaiting task
    /// unblocks. The read loop then surfaces the error and the session terminates
    /// and reconnects. Without this, an ended output stream left sendToServer
    /// suspended forever, freezing the UI ("not responsive").
    private func failConnection() {
        state = .error
        gotInputBuffer.error(NetworkChannelError.ReadError)
        rejectAllPendingWrites(NetworkChannelError.WriteError)
    }
    
    deinit {
        self.inputBufferPointer?.deallocate()
        disconnect()
    }
    
    private func deinitStream(stream: Stream) {
        stream.remove(from: RunLoop.main, forMode: RunLoop.Mode.default)
        stream.close()
        stream.delegate = nil
    }
  
    public func getFromServer<T>(type: T.Type) async throws -> T {
        let result: [T] = try await self.getFromServer(type: type, count: 1)
        return result[0]
    }
    
    public func getFromServer(count: Int) async throws -> Data {
        let bytes: [UInt8] = try await getFromServer(type: UInt8.self, count: count)
        return Data(bytes)
    }
    
    public func getFromServer<T>(type: T.Type, count: Int) async throws -> [T] {
        guard state == .open else {
            throw state == .error ? NetworkChannelError.ReadError : NetworkChannelError.GetDataFromNonOpenChannel
        }

        @inline(__always) func mayDeallocateBuffer() {
            if self.inputBufferIndex >= self.bytesInInputBuffer {
                self.inputBufferPointer?.deallocate()
                self.inputBufferPointer = nil
            }
        }

        func doGetFromServer() async throws -> [T] {
            let bytesToGet = MemoryLayout<T>.size * count

            if self.inputBufferIndex + bytesToGet <= self.bytesInInputBuffer {
                let buffer = UnsafeMutableBufferPointer(start: self.inputBufferPointer!.advanced(by: self.inputBufferIndex).assumingMemoryBound(to: T.self), count: count)
                self.inputBufferIndex += bytesToGet
                let array = Array(buffer)
                mayDeallocateBuffer()
                return array
            } else {
                let resultPointer = UnsafeMutableRawPointer.allocate(byteCount: bytesToGet, alignment: 8)
                let resultBytes = UnsafeMutableRawBufferPointer(start: resultPointer, count: bytesToGet)
                let inputBuffer = UnsafeMutableRawBufferPointer(start: self.inputBufferPointer!, count: self.inputBufferSize)
                var gotSoFar = 0

                while self.inputBufferIndex < self.bytesInInputBuffer {
                    resultBytes[gotSoFar] = inputBuffer[self.inputBufferIndex]
                    self.inputBufferIndex += 1
                    gotSoFar += 1
                }

                mayDeallocateBuffer()

                while gotSoFar < bytesToGet {
                    let bufferInfo = try await self.gotInputBuffer.wait()
                    self.inputBufferPointer = bufferInfo.buffer
                    self.bytesInInputBuffer = bufferInfo.byteCount
                    self.inputBufferIndex = 0

                    let inputBuffer = UnsafeMutableRawBufferPointer(start: self.inputBufferPointer!, count: self.inputBufferSize)
                    let bytesToProcess = min(bytesToGet - gotSoFar, self.bytesInInputBuffer)
                    self.inputBufferIndex = 0

                    for _ in 0 ..< bytesToProcess {
                        resultBytes[gotSoFar] = inputBuffer[self.inputBufferIndex]
                        gotSoFar += 1
                        self.inputBufferIndex += 1
                    }

                    mayDeallocateBuffer()
                }

                let buffer = UnsafeMutableBufferPointer(start: resultPointer.assumingMemoryBound(to: T.self), count: count)
                let theResult = Array(buffer)
                resultPointer.deallocate()
                return theResult
            }
        }

        if count == 0 { return [] }

        if self.inputBufferPointer == nil {
            let bufferInfo = try await self.gotInputBuffer.wait()
            self.inputBufferPointer = bufferInfo.buffer
            self.bytesInInputBuffer = bufferInfo.byteCount
            self.inputBufferIndex = 0
            return try await doGetFromServer()
        } else {
            return try await doGetFromServer()
        }
    }

    public func sendToServer<T>(dataItem: T) async throws -> NetworkChannel {
        let dataBuffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        dataBuffer.initialize(to: dataItem)

        defer { dataBuffer.deallocate() }

        let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NetworkChannel, Error>) in
            // Serialize ALL write-queue access on the main thread, where the stream
            // delegate's writeNextChunk also runs. Concurrent senders (gestures + the
            // ping + the frame-update-request, all on the cooperative pool) previously
            // mutated writeRequestQueue/activeWriteRequest unsynchronized against the
            // main-thread delegate — a data race that could corrupt the queue or
            // double-resume/orphan a continuation. The state check is here too, so it
            // reads `state` on the thread that writes it.
            DispatchQueue.main.async {
                guard self.state == .open else {
                    cont.resume(throwing: self.state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel)
                    return
                }
                self.writeRequestQueue.append(Request(length: MemoryLayout<T>.size, buffer: OpaquePointer(dataBuffer), fulfill: { _ in
                    cont.resume(returning: self)
                }, reject: { error in
                    cont.resume(throwing: error)
                }))
                self.initiateNextWriteRequest()
            }
        }

        return self
    }
    
    public func sendToServer<T: Collection>(dataItems: T) async throws -> NetworkChannel {
        guard state == .open else {
            throw state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel
        }

        let count = dataItems.count
        let dataPointer = UnsafeMutablePointer<T.Iterator.Element>.allocate(capacity: count)
        let dataBuffer = UnsafeMutableBufferPointer(start: dataPointer, count: count)
        _ = dataBuffer.initialize(from: dataItems)

        defer { dataPointer.deallocate() }

        let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NetworkChannel, Error>) in
            // See sendToServer(dataItem:) — all write-queue access on the main thread.
            DispatchQueue.main.async {
                guard self.state == .open else {
                    cont.resume(throwing: self.state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel)
                    return
                }
                self.writeRequestQueue.append(Request(length: MemoryLayout<T.Iterator.Element>.size * count, buffer: OpaquePointer(dataBuffer.baseAddress!), fulfill: { _ in
                    cont.resume(returning: self)
                }, reject: { error in
                    cont.resume(throwing: error)
                }))
                self.initiateNextWriteRequest()
            }
        }

        return self
    }
    
 
    // MARK: Internal write handlers
    
    private func initiateNextWriteRequest() {
        if activeWriteRequest == nil && writeRequestQueue.count > 0 {
            activeWriteRequest = ActiveRequest(request: writeRequestQueue.removeFirst())
            writeNextChunk()
        }
    }

    func writeNextChunk() {
        if let activeRequest = activeWriteRequest, let stream = outputStream, self.outputStream!.hasSpaceAvailable {
            let count = stream.write(activeRequest.buffer, maxLength: activeRequest.request.length - activeRequest.bytesDone)
            
            activeRequest.bytesDone += count
            activeRequest.buffer = activeRequest.buffer.advanced(by: count)
            
            if activeRequest.bytesDone == activeRequest.request.length {
                activeWriteRequest = nil
                activeRequest.fulfill(OpaquePointer(activeRequest.buffer))

                initiateNextWriteRequest()
            }
        }
    }

    // MARK: Stream delegate
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) {
            switch state {
            case .opening(_, let reject), .firstStreamOpen(_, let reject):
                // connect() opens TWO streams on the main RunLoop. A bad/unreachable
                // host makes BOTH fire .errorOccurred. Transition out of the opening
                // state BEFORE rejecting so the second stream's error can't resume the
                // connect() continuation a second time (the "SWIFT TASK CONTINUATION
                // MISUSE: tried to resume its continuation more than once" crash).
                state = .error
                reject(NetworkChannelError.CannotConnectToServer("\(server):\(port)"))
            default:
                failConnection()
            }
        }
        else {
            if eventCode.contains(.openCompleted) {
                switch state {
                case let .opening(fulfill, reject): state = .firstStreamOpen(fulfill, reject)
                case let .firstStreamOpen(fulfill, _):
                    state = .open
                    fulfill(self)
                default:
                    // A late/stray openCompleted (e.g. the sibling stream opening
                    // after the other already errored, or after .open) is harmless —
                    // never trap on it.
                    NSLog("Ignoring unexpected openCompleted in state \(state)")
                }
            }
            
            if eventCode.contains(.hasBytesAvailable) {
                assert(aStream === inputStream)
                
                while inputStream!.hasBytesAvailable {
                    let buffer = UnsafeMutableRawPointer.allocate(byteCount: self.inputBufferSize, alignment: 8)
                    let count = self.inputStream!.read(buffer.assumingMemoryBound(to: UInt8.self), maxLength: self.inputBufferSize)

                    self.gotInputBuffer.send((byteCount: count, buffer: buffer))
                }
            }
            
            if eventCode.contains(.hasSpaceAvailable) {
                assert(aStream === outputStream)
                writeNextChunk()
            }
            
            if eventCode.contains(.endEncountered) {
                NSLog("endOfStream on \(aStream === inputStream ? "input" : "output") stream")
                // Either stream ending means the connection is gone. Fail all pending
                // I/O so awaiting tasks unblock (previously an ended OUTPUT stream was
                // only logged, leaving sendToServer suspended forever).
                failConnection()
            }
        }
    }
}

