//
//  NetworkChannel.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 13.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import Foundation
import PromiseKit

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
    
    init(request: Request) {
        self.request = request
        self.bytesDone = 0
        self.buffer = UnsafeMutablePointer<UInt8>(request.buffer)
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
    private let gotInputBuffer = PromisedQueue<(byteCount: Int, buffer: UnsafeMutableRawPointer)>()
    
    init(server: String, port: Int) {
        self.server = server
        self.port = port
        self.activeWriteRequest = nil
        
        self.bytesInInputBuffer = 0
        self.inputBufferIndex = 0
    }
    
    func connect() -> Promise<NetworkChannel> {
        guard state == .closed else {
            return Promise(error: NetworkChannelError.OpeningNonClosedChannel)
        }
        
        Stream.getStreamsToHost(withName: server, port: port, inputStream: &inputStream, outputStream: &outputStream)
        
        if let input = inputStream, let output = outputStream {
            input.delegate = self
            output.delegate = self
            
            input.schedule(in: RunLoop.main, forMode: .defaultRunLoopMode)
            output.schedule(in: RunLoop.main, forMode: .defaultRunLoopMode)
            
            input.open()
            output.open()
           
            return Promise<NetworkChannel> { fulfill, reject in
                state = .opening(fulfill, reject)
            }
        }
        else {
            return Promise(error: NetworkChannelError.CannotCreateStream("\(server):\(port)"))
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
        
        writeRequestQueue = []
        activeWriteRequest = nil
    }
    
    deinit {
        self.inputBufferPointer?.deallocate(bytes: inputBufferSize, alignedTo: 8)
        disconnect()

        self.gotInputBuffer.queue.forEach { bufferInfo in bufferInfo.buffer.deallocate(bytes: self.inputBufferSize, alignedTo: 8) }
    }
    
    private func deinitStream(stream: Stream) {
        stream.remove(from: RunLoop.main, forMode: .defaultRunLoopMode)
        stream.close()
        stream.delegate = nil
    }
  
    public func getFromServer<T>(type: T.Type) -> Promise<T> {
        return self.getFromServer(type: type, count: 1).then(on: zalgo) { $0[0] }
    }
    
    public func getFromServer<T>(type: T.Type, count: Int) -> Promise<[T]> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.ReadError : NetworkChannelError.GetDataFromNonOpenChannel)
        }
        
        @inline(__always) func mayDeallocateBuffer() {
            // If all data has been consumed, deallocate the buffer
            if self.inputBufferIndex >= self.bytesInInputBuffer {
                self.inputBufferPointer?.deallocate(bytes: self.inputBufferSize, alignedTo: 8)
                self.inputBufferPointer = nil
            }
        }
        
        // Get data from buffer (at this point it is ensured that at least one buffer has been received)
        func doGetFromServer() -> Promise<[T]> {
            let bytesToGet = MemoryLayout<T>.size * count
            
            if self.inputBufferIndex + bytesToGet <= self.bytesInInputBuffer {   // Enough bytes are in the buffer
                let buffer = UnsafeMutableBufferPointer(start: self.inputBufferPointer!.advanced(by: self.inputBufferIndex).assumingMemoryBound(to: T.self), count: count)
                
                self.inputBufferIndex += bytesToGet
                let result = Promise<[T]>(value: Array(buffer))
                mayDeallocateBuffer()
                
                return result
            }
            else {  // More bytes need to be read
                let resultPointer = UnsafeMutableRawPointer.allocate(bytes: bytesToGet, alignedTo: 8)
                let resultBytes = UnsafeMutableRawBufferPointer(start: resultPointer, count: bytesToGet)
                let inputBuffer = UnsafeMutableRawBufferPointer(start: self.inputBufferPointer!, count: self.inputBufferSize)
                var gotSoFar = 0
                
                while(self.inputBufferIndex < self.bytesInInputBuffer) {
                    resultBytes[gotSoFar] = inputBuffer[self.inputBufferIndex]
                    self.inputBufferIndex += 1
                    gotSoFar += 1
                }
                
                mayDeallocateBuffer()
                
                return PromisedLand.doWhile {
                    return self.gotInputBuffer.wait().then(on: zalgo) { bufferInfo in
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
                        return Promise(value: gotSoFar < bytesToGet)         // Continue as long as not all needed bytes are in the result bytes buffer
                    }
                }.then { _ in
                    let buffer = UnsafeMutableBufferPointer(start: resultPointer.assumingMemoryBound(to: T.self), count: count)
                    let theResult = Promise<[T]>(value: Array(buffer))
                    
                    resultPointer.deallocate(bytes: bytesToGet, alignedTo: 8)
                    
                    return theResult
                }
            }
        }
        
        if count == 0 {
            return Promise<[T]>(value: [])
        }
        
        if self.inputBufferPointer == nil {
            return self.gotInputBuffer.wait().then { bufferInfo in
                self.inputBufferPointer = bufferInfo.buffer
                self.bytesInInputBuffer = bufferInfo.byteCount
                self.inputBufferIndex = 0
                
                return doGetFromServer()
            }
        }
        else {
            return doGetFromServer()
        }
    }

    public func sendToServer<T>(dataItem: T) -> Promise<NetworkChannel> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel)
        }
        
        // Copy data to a buffer that will live until data is actually sent
        let dataBuffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        dataBuffer.initialize(to: dataItem)
        
        return Promise<OpaquePointer>(resolvers: { fulfill, reject in
            writeRequestQueue.append(Request(length: MemoryLayout<T>.size, buffer: OpaquePointer(dataBuffer), fulfill: fulfill, reject: reject))
            initiateNextWriteRequest()
        }).then(on: zalgo) {
            _ in self
        }.always(on: zalgo) {
            // Data was sent, dealloc temporary buffer
            dataBuffer.deallocate(capacity: 1)
        }
    }
    
    public func sendToServer<T : Collection>(dataItems: T) -> Promise<NetworkChannel> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel)
        }

        let count = dataItems.count as! Int
        let dataPointer = UnsafeMutablePointer<T.Iterator.Element>.allocate(capacity: count)
        let dataBuffer = UnsafeMutableBufferPointer(start: dataPointer, count: count)

        let _ = dataBuffer.initialize(from: dataItems)
        
        return Promise<OpaquePointer>(resolvers: { fulfill, reject in
            writeRequestQueue.append(Request(length: MemoryLayout<T.Iterator.Element>.size * count, buffer: OpaquePointer(dataBuffer.baseAddress!), fulfill: fulfill, reject: reject))
            initiateNextWriteRequest()
        }).then(on: zalgo) {
            _ in self
        }.always(on: zalgo) {
            // Data was sent, dealloc temporary buffer
            dataPointer.deallocate(capacity: count)
        }
    }
    
 
    // MARK: Intermal write handlers
    
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
                activeRequest.request.fulfill(OpaquePointer(activeRequest.buffer))
                activeWriteRequest = nil
                
                initiateNextWriteRequest()
            }
        }
    }

    // MARK: Stream delegate
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) {
            switch state {
            case .opening(_, let reject):
                reject(NetworkChannelError.CannotConnectToServer("\(server):\(port)"))
            case .firstStreamOpen(_, let reject):
                reject(NetworkChannelError.CannotConnectToServer("\(server):\(port)"))
            default:
                state = .error

                self.gotInputBuffer.error(NetworkChannelError.ReadError)
                
                if let activeRequest = activeWriteRequest {
                    activeRequest.request.reject(NetworkChannelError.WriteError)
                }
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
                    assert(false, "Unexpected openCompleted")
                }
            }
            
            if eventCode.contains(.hasBytesAvailable) {
                assert(aStream === inputStream)
                
                while inputStream!.hasBytesAvailable {
                    let buffer = UnsafeMutableRawPointer.allocate(bytes: self.inputBufferSize, alignedTo: 8)
                    let count = self.inputStream!.read(buffer.assumingMemoryBound(to: UInt8.self), maxLength: self.inputBufferSize)
                    
                    self.gotInputBuffer.send((byteCount: count, buffer: buffer))
                }
            }
            
            if eventCode.contains(.hasSpaceAvailable) {
                assert(aStream === outputStream)
                writeNextChunk()
            }
        }
    }
}
