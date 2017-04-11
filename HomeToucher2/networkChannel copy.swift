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

    private var readRequestQueue: [Request] = []
    private var writeRequestQueue: [Request] = []
    
    private var activeReadRequest: ActiveRequest?
    private var activeWriteRequest: ActiveRequest?
    
   init(server: String, port: Int) {
        self.server = server
        self.port = port
        self.activeReadRequest = nil
        self.activeWriteRequest = nil
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
        
        readRequestQueue = []
        writeRequestQueue = []
        activeWriteRequest = nil
        activeReadRequest = nil
    }
    
    deinit {
        disconnect()
    }
    
    private func deinitStream(stream: Stream) {
        stream.remove(from: RunLoop.main, forMode: .defaultRunLoopMode)
        stream.close()
        stream.delegate = nil
    }
  
    public func getFromServer<T>() -> Promise<T> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.ReadError : NetworkChannelError.GetDataFromNonOpenChannel)
        }
        
        let bytesBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: MemoryLayout<T>.size)
        
        return Promise<OpaquePointer>
            { fulfill, reject in
                readRequestQueue.append(Request(length: MemoryLayout<T>.size, buffer: OpaquePointer(bytesBuffer) , fulfill: fulfill, reject: reject))
                initiateNextReadRequest()
            }.then { rawBuffer in
                let result = UnsafeMutablePointer<T>(rawBuffer).move()
                
                return Promise<T>(value: result)
            }
            .always {
                bytesBuffer.deallocate(capacity: MemoryLayout<T>.size)
        }
    }
    
    public func getFromServer<T>(count: Int) -> Promise<[T]> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.ReadError : NetworkChannelError.GetDataFromNonOpenChannel)
        }
        
        if count == 0 {
            return Promise<[T]>(value: [])
        }
        else {
            let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
            
            return Promise<OpaquePointer> { fullfill, reject in
                readRequestQueue.append(Request(length: count*MemoryLayout<T>.size, buffer: OpaquePointer(buffer), fulfill: fullfill, reject: reject))
                initiateNextReadRequest()
            }.then { rawBuffer in
                let buffer = UnsafeBufferPointer(start: UnsafePointer<T>(rawBuffer), count: count)
                    
                return Promise<[T]>(value: Array(buffer))
            }.always {
                buffer.deallocate(capacity: count)
            }
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
        }).then {
            _ in self
        }.always {
            // Data was sent, dealloc temporary buffer
            dataBuffer.deallocate(capacity: 1)
        }
    }
    
    public func sendToServer<T : Collection>(dataItems: T) -> Promise<NetworkChannel> {
        guard state == .open else {
            return Promise(error: state == .error ? NetworkChannelError.WriteError : NetworkChannelError.SendingToNonOpenChannel)
        }

        let count = dataItems.count as! Int
        let dataBuffer = UnsafeMutablePointer<T.Generator.Element>.allocate(capacity: count)
        dataBuffer.initialize(from: dataItems)
        
        return Promise<OpaquePointer>(resolvers: { fulfill, reject in
            writeRequestQueue.append(Request(length: MemoryLayout<T.Iterator.Element>.size * count, buffer: OpaquePointer(dataBuffer), fulfill: fulfill, reject: reject))
            initiateNextWriteRequest()
        }).then {
            _ in self
        }.always {
            // Data was sent, dealloc temporary buffer
            dataBuffer.deallocate(capacity: count)
        }
    }
    
   // MARK: Internal read handlers
    
    private func initiateNextReadRequest() {
        if activeReadRequest == nil && readRequestQueue.count > 0 {
            activeReadRequest = ActiveRequest(request: readRequestQueue.removeFirst())
            readNextChunk()
        }
    }
    
    private func readNextChunk() {
        if let activeRequest = activeReadRequest, let stream = inputStream {
            if (inputStream?.hasBytesAvailable)! {
                let count = stream.read(activeRequest.buffer, maxLength: activeRequest.request.length - activeRequest.bytesDone)
                
                activeRequest.bytesDone += count
                activeRequest.buffer = activeRequest.buffer.advanced(by: count)
                
                if activeRequest.bytesDone == activeRequest.request.length {
                    activeRequest.request.fulfill(activeRequest.request.buffer)
                    activeReadRequest = nil
                }
            }
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
        if let activeRequest = activeWriteRequest, let stream = outputStream {
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
                
                if let activerequest = activeReadRequest {
                    activerequest.request.reject(NetworkChannelError.ReadError)
                }
                
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
                    fulfill(self)
                    state = .open
                default:
                    assert(false, "Unexpected openCompleted")
                }
            }
            
            if eventCode.contains(.hasBytesAvailable) {
                assert(aStream === inputStream)
                readNextChunk()
            }
            else if eventCode.contains(.hasSpaceAvailable) {
                assert(aStream === outputStream)
                writeNextChunk()
            }
        }
    }
}
