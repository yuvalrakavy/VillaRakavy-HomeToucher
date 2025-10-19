//
//  RemoteFrameBufferSession.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 25/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit

public typealias PixelType = UInt32

public protocol FrameBitmapView {
    func allocateFrameBitmap(size: CGSize)
    func freeFrameFrameBitmap()
    
    func redisplay(rect: CGRect)
    func getHitPoint(recognizer: UIGestureRecognizer) -> CGPoint?

    var frameBitmap: UnsafeMutableBufferPointer<PixelType> { get }
}

@MainActor
public class RemoteFrameBufferSession {
    internal var model: HomeTouchModel
    internal var view: FrameBitmapView
    internal var frameBufferInfo: FrameBufferInfo?

    // 1) Add these stored properties
    private var pressStream: AsyncStream<(hitPoint: CGPoint, state: UIGestureRecognizer.State)>!
    private var pressContinuation: AsyncStream<(hitPoint: CGPoint, state: UIGestureRecognizer.State)>.Continuation!

    private var tapStream: AsyncStream<CGPoint>!
    private var tapContinuation: AsyncStream<CGPoint>.Continuation!

    private let cacheManager: CacheManager
    
    let debugLevel = 1
    
    let apiEncoding: Int32 = 102                  // Encoding used for API calls (fixed version, old encoding (100) is obsolite)
    let clientSideCachingEncoding: Int32 = 101    // Encoding used for client side caching
    
    let invokeApiMessage: UInt8 = 100
    let frameUpdateExtensionMessage: UInt8 = 101  // Message from server: frame update with length and hash (and optionally data)
    let sendFrameDataRequest: UInt8 = 101         // client asks server to send/drop frame update data
    
    let serverPingInterval =                    5 * 60.0               // Priodically send "setCutText" message to the server to ensure good connection
    
    private var onPress: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    private var onTap: ((_ hitPoint: CGPoint) -> Void)?
    
    private var activeSession: SessionInfo?
    
    let initializationStopwatch = StopWatch("Initialization")
    
    init(model: HomeTouchModel, frameBitmapView: FrameBitmapView, cacheManager: CacheManager) {
        self.model = model
        self.view = frameBitmapView
        self.activeSession = nil
        self.serverApiVersion = nil
        self.cacheManager = cacheManager
        
        self.pressStream = AsyncStream { continuation in
            self.pressContinuation = continuation
        }
        self.tapStream = AsyncStream { continuation in
            self.tapContinuation = continuation
        }
    }
    
    func debug(_ message: String, minDebugLevel: Int = 1) {
        if(self.debugLevel >= minDebugLevel) {
            NSLog(message)
        }
    }
    
    public func begin(server: String, port: Int, onSessionStarted: (() -> Void)? = nil) async throws {
        debug("Starting RFB session")
        initializationStopwatch.start()

        func runSession(_ networkChannel: NetworkChannel) async throws {
            let pingTask = Task.detached { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await MainActor.run { self.debug("Ping: Sending to server") }
                    if let channel = await MainActor.run (body: { self.activeSession?.networkChannel }) {
                        let data = await MainActor.run { self.formatSetCutText(text: "") }
                        _ = try? await channel.sendToServer(dataItems: data)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(self.serverPingInterval * 1_000_000_000))
                }
            }

            onSessionStarted?()

            defer {
                networkChannel.disconnect()
                self.view.freeFrameFrameBitmap()
                NSLog("Invalidating ping timer")
                pingTask.cancel()
            }

            self.activeSession = SessionInfo(networkChannel: networkChannel, task: nil, cancel: {})

            let sessionTask = Task { [weak self] in
                guard let self else { return }
                // Start server input handling as a child task and keep a strong reference locally.
                let serverInputTask = Task { [weak self] () -> Bool in
                    guard let self else { return false }
                    do {
                        return try await self.handleServerInput(networkChannel: networkChannel)
                    } catch {
                        await MainActor.run { self.debug("handleServerInput error: \(error)") }
                        return false
                    }
                }

                await withTaskCancellationHandler {
                    async let gestures: Bool = self.handleGestures(networkChannel: networkChannel)
                    let serverInput = await serverInputTask.value
                    _ = await (gestures, serverInput)
                } onCancel: {
                    // Explicitly cancel the unstructured child so it can unblock promptly
                    NSLog("session task was canceled")
                    serverInputTask.cancel()
                }
            }
            self.activeSession?.task = sessionTask
            self.activeSession?.cancel = { NSLog("Canceling session task"); sessionTask.cancel() }

            await sessionTask.value
        }

        let networkChannel = try await self.initSession(server: server, port: port)
        try await runSession(networkChannel)
    }
    
    public func terminate() {
        debug("RFBsession.terminate")
        if let session = self.activeSession {
            self.serverApiVersion = nil
            self.activeSession = nil
            session.cancel()
        }
    }
    
    public func getRecognizers() -> [UIGestureRecognizer] {
        return [
            UILongPressGestureRecognizer(target: self, action: #selector(resolveOnLongPress)),
            UITapGestureRecognizer(target: self, action: #selector(resolveOnTap(_:)))
        ]
    }
    
    public var onApiCall: (([String: String]) -> Void)?
    
    public func invokeApi(parameters: [String: String]) {
        if let _ = self.serverApiVersion {
            debug("Sending InvokeAPI parameters: \(parameters)", minDebugLevel: 2)
            Task { [weak self] in
                guard let self else { return }
                let data = self.formatInvokeApiCommand(parameters: parameters)
                _ = try? await self.activeSession?.networkChannel.sendToServer(dataItems: data)
            }
        }
    }
    
    public var serverApiVersion: Int?
    
    private func initSession(server: String, port: Int) async throws -> NetworkChannel {
        let networkChannel = NetworkChannel(server: server, port: port)

        func sendUpdateRequestCommand() async throws -> NetworkChannel {
            self.debug("Sending frameUpdateRequest command", minDebugLevel: 2)
            return try await networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: false))
        }

        func getSessionName(_ frameBufferInfo: FrameBufferInfo) async throws -> String {
            let sessionNameBytes: [UInt8] = try await networkChannel.getFromServer(type: UInt8.self, count: Int(frameBufferInfo.nameLength))
            return String(bytes: sessionNameBytes, encoding: String.Encoding.windowsCP1253) ?? "Cannot decode name"
        }

        _ = try await networkChannel.connect()
        _ = try await self.doVersionHandshake(networkChannel)
        _ = try await self.doSecurityHandshake(networkChannel)

        let unfixedframeBufferInfo: FrameBufferInfo = try await networkChannel.getFromServer(type: FrameBufferInfo.self)
        var frameBufferInfo = unfixedframeBufferInfo
        frameBufferInfo.height = frameBufferInfo.height.bigEndian
        frameBufferInfo.width = frameBufferInfo.width.bigEndian
        frameBufferInfo.nameLength = frameBufferInfo.nameLength.bigEndian
        frameBufferInfo.pixelFormat.redMax = frameBufferInfo.pixelFormat.redMax.bigEndian
        frameBufferInfo.pixelFormat.greenMax = frameBufferInfo.pixelFormat.greenMax.bigEndian
        frameBufferInfo.pixelFormat.blueMax = frameBufferInfo.pixelFormat.blueMax.bigEndian
        
        self.frameBufferInfo = frameBufferInfo
        self.view.allocateFrameBitmap(size: frameBufferInfo.size)

        let sessionName: String = try await getSessionName(frameBufferInfo)
        self.debug("RFB session name \(sessionName)")

        let encodingList = self.model.DisableCaching ? [5, 0, self.apiEncoding] : [5, 0, self.apiEncoding, self.clientSideCachingEncoding]
        _ = try await networkChannel.sendToServer(dataItems: self.formatSetEncodingCommand(supportedEncoding: encodingList))
        let ch: NetworkChannel = try await sendUpdateRequestCommand()
        return ch
    }
    
    private func doVersionHandshake(_ networkChannel: NetworkChannel) async throws -> NetworkChannel {
        let serverVersionBytes: [UInt8] = try await networkChannel.getFromServer(type: UInt8.self, count: 12)
        let version = [UInt8]("RFB 003.008\n".utf8)
        let serverVersion = String(bytes: serverVersionBytes, encoding: String.Encoding.utf8)!
        self.debug("Sever RFB version \(serverVersion)")
        _ = try await networkChannel.sendToServer(dataItems: version)
        return networkChannel
    }
    
    private func doSecurityHandshake(_ networkChannel: NetworkChannel) async throws -> NetworkChannel {
        func handleSecurityResult(_ securityResult: UInt32) async throws -> NetworkChannel {
            if securityResult.bigEndian == 0 {
                _ = try await networkChannel.sendToServer(dataItem: UInt8(1))
                return networkChannel
            } else {
                let errorMessage = try await self.getErrorMessage(networkChannel: networkChannel)
                throw SessionError.SecurityFailed(errorMessage: errorMessage)
            }
        }

        let _ = try await self.doGetAuthenticationMethods(networkChannel)
        _ = try await networkChannel.sendToServer(dataItem: UInt8(1))
        let securityResult: UInt32 = try await networkChannel.getFromServer(type: UInt32.self)
        return try await handleSecurityResult(securityResult)
    }
    
    private func doGetAuthenticationMethods(_ networkChannel: NetworkChannel) async throws -> [UInt8] {
        func handleAuthenticationMethod(_ methodCount: UInt8) async throws -> [UInt8] {
            if methodCount > 0 {
                return try await networkChannel.getFromServer(type: UInt8.self, count: Int(methodCount))
            } else {
                let errorMessage = try await self.getErrorMessage(networkChannel: networkChannel)
                throw SessionError.InvalidConnection(errorMessage: errorMessage)
            }
        }

        let methodCount: UInt8 = try await networkChannel.getFromServer(type: UInt8.self)
        return try await handleAuthenticationMethod(methodCount)
    }
    
    private func getErrorMessage(networkChannel: NetworkChannel) async throws -> String {
        let count: UInt32 = try await networkChannel.getFromServer(type: UInt32.self)
        let bytes: [UInt8] = try await networkChannel.getFromServer(type: UInt8.self, count: Int(count.bigEndian))
        return String(bytes: bytes, encoding: String.Encoding.utf8)!
    }
    
    private func handleServerInput(networkChannel: NetworkChannel) async throws -> Bool {
        initializationStopwatch.report()
        while !Task.isCancelled {
            let shouldContinue = try await self.handleServerReply(networkChannel: networkChannel)
            if !shouldContinue { return false }
        }
        return false
    }
    
    private func handleServerReply(networkChannel: NetworkChannel) async throws -> Bool {
        func processReply(_ reply: UInt8) async throws -> Bool {
            switch reply {
            case 0:
                self.debug("Got frameBufferUpdate message from server", minDebugLevel: 2)
                let _ = try await self.processFrameBufferUpdate(networkChannel: networkChannel)
                self.debug("Send FrameUpdateRequestCommand (incremental: true)", minDebugLevel: 2)
                _ = try await networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: true))
                return true
            case self.frameUpdateExtensionMessage:
                self.debug("Got frameBufferUpdateExtension message from server", minDebugLevel: 2)
                let getFrameDataFromServer = try await self.processFrameUpdateExtension(networkChannel: networkChannel)
                if getFrameDataFromServer {
                    self.debug("Send SendFrameDataCommand)", minDebugLevel: 2)
                    _ = try await networkChannel.sendToServer(dataItems: self.formatSendFrameDataCommand())
                } else {
                    self.debug("Send FrameUpdateRequestCommand (incremental: true)", minDebugLevel: 2)
                    _ = try await networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: true))
                }
                return true
            case self.invokeApiMessage:
                self.debug("Got invoke API from server", minDebugLevel: 2)
                let _ = try await self.processApiCall(networkChannel: networkChannel)
                return true
            default:
                return false
            }
        }

        do {
            let reply: UInt8 = try await networkChannel.getFromServer(type: UInt8.self)
            return try await processReply(reply)
        } catch {
            self.debug("handleServerReply - error -- calling self.terminate: \(error)")
            self.terminate()
            return false
        }
    }

    private func processFrameUpdateExtension(networkChannel: NetworkChannel) async throws -> Bool {
        let hasData: UInt8 = try await networkChannel.getFromServer(type: UInt8.self)
        let rawHeader: [UInt32] = try await networkChannel.getFromServer(type: UInt32.self, count: 2)
        let cacheKey = CacheKey(length: rawHeader[0].bigEndian, hashCode: rawHeader[1].bigEndian)

        var keyAndFrameData: (key: CacheKey, frameData: Data)? = nil
        if hasData != 0 {
            let frameData: Data = try await networkChannel.getFromServer(count: Int(cacheKey.length))
            self.cacheManager.add(key: cacheKey, frameData: frameData)
            keyAndFrameData = (key: cacheKey, frameData: frameData)
        } else {
            let getDataFromCacheStopwatch = StopWatch("Get data from cache")
            getDataFromCacheStopwatch.start()
            if let frameData = self.cacheManager.get(key: cacheKey) {
                getDataFromCacheStopwatch.report()
                keyAndFrameData = (key: cacheKey, frameData: frameData)
            } else {
                getDataFromCacheStopwatch.stop()
            }
        }

        if let k = keyAndFrameData {
            let applyFrameBufferUpdateStopwatch = StopWatch("ApplyFrameData")
            applyFrameBufferUpdateStopwatch.start()
            self.applyFrameBufferUpdate(frameData: k.frameData)
            applyFrameBufferUpdateStopwatch.report()
            return false
        } else {
            return true
        }
    }
    
    private func receiveString(networkChannel: NetworkChannel) async throws -> String? {
        let count: UInt16 = try await networkChannel.getFromServer(type: UInt16.self)
        if count == 0 { return nil }
        let bytes: [UInt8] = try await networkChannel.getFromServer(type: UInt8.self, count: Int(count.bigEndian) * 2)
        return String(bytes: bytes, encoding: String.Encoding.utf16BigEndian)
    }
    
    typealias OptionalNameValuePair = (name: String, value: String)?
    
    private func receiveNameValue(networkChannel: NetworkChannel) async throws -> OptionalNameValuePair {
        let mayBeName = try await self.receiveString(networkChannel: networkChannel)
        if let name = mayBeName {
            let mayBeValue = try await self.receiveString(networkChannel: networkChannel)
            if let value = mayBeValue {
                return (name: name, value: value)
            }
        }
        return nil
    }
    
    private func processApiCall(networkChannel: NetworkChannel) async throws -> Bool {
        var dict = [String:String]()
        _ = try await networkChannel.getFromServer(type: UInt8.self)
        while true {
            let maybeNameValuePair = try await self.receiveNameValue(networkChannel: networkChannel)
            if let nameValuePair = maybeNameValuePair {
                dict[nameValuePair.name] = nameValuePair.value
            } else {
                break
            }
        }
        self.onApiCall?(dict)
        self.debug("ProcessApiCall returning true")
        return true
    }
    
    private func handlePressGesture(networkChannel: NetworkChannel) async -> Bool {
        self.debug("Handling press gesture")
        for await pressInfo in pressStream {
            self.debug("Press: \(pressInfo)")
            if Task.isCancelled { return false }
            switch pressInfo.state {
            case .began:
                _ = try? await networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: true))
            case .cancelled, .ended:
                _ = try? await networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: false))
            default:
                break
            }
        }
        return true
    }
    
    private func handleTapGesture(networkChannel: NetworkChannel) async -> Bool {
        self.debug("Handling tap gesture")
        for await hitPoint in tapStream {
            self.debug("Tap: \(hitPoint)")
            if Task.isCancelled { return false }
            self.debug("Send PointerEvent at \(hitPoint)", minDebugLevel: 2)
            _ = try? await networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: true))
            _ = try? await networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: false))
        }
        return true
    }
    
    private func handleGestures(networkChannel: NetworkChannel) async -> Bool {
        async let pressResult: Bool = handlePressGesture(networkChannel: networkChannel)
        async let tapResult: Bool = handleTapGesture(networkChannel: networkChannel)
        _ = await (pressResult, tapResult)
        return true
    }
    
    // Get byte array represntng a given value
    private func toByteArray<T>(_ value: T) -> [UInt8] {
        var value = value
        return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) {
                Array(UnsafeBufferPointer(start: $0, count: MemoryLayout<T>.size))
            }
        }
    }
    
    private func formatSetEncodingCommand(supportedEncoding: [Int32]) -> [UInt8] {
        var command: [UInt8] = [2, 0]
        
        command.append(contentsOf: toByteArray(UInt16(supportedEncoding.count).bigEndian))
        for encoding in supportedEncoding {
            command.append(contentsOf: toByteArray(encoding.bigEndian))
        }
        
        return command
    }
    
    private func formatFrameBufferUpdateRequstCommand(incremental: Bool = true) -> [UInt8] {
        var command: [UInt8] = [3, incremental ? 1 : 0]
        
        command.append(contentsOf: toByteArray(UInt16(0).bigEndian))     // X position
        command.append(contentsOf: toByteArray(UInt16(0).bigEndian))     // Y position
        command.append(contentsOf: toByteArray(self.frameBufferInfo!.width.bigEndian))    // width
        command.append(contentsOf: toByteArray(self.frameBufferInfo!.height.bigEndian))    // width
        
        return command
    }
    
    private func formatSendFrameDataCommand() -> [UInt8] {
        [sendFrameDataRequest]
    }
    
    private func formatPointerEvent(hitPoint: CGPoint, buttonDown: Bool) -> [UInt8] {
        var command: [UInt8] = [5, buttonDown ? 1 : 0]
        
        command.append(contentsOf: toByteArray(UInt16(hitPoint.x).bigEndian))
        command.append(contentsOf: toByteArray(UInt16(hitPoint.y).bigEndian))
        
        return command
    }
    
    private func formatSetCutText(text: String) -> [UInt8] {
        var command: [UInt8] =  [6, 0, 0, 0];
        
        command.append(contentsOf: toByteArray(UInt32(text.count).bigEndian));
        command.append(contentsOf: text.utf8);
        
        return command;
    }
    
    private func formatInvokeApiCommand(parameters: [String: String]) -> [UInt8] {
        func getStringBytes(_ s: String) -> [UInt8] {
            let l = s.count
            
            return  s.utf16.reduce([UInt8(l >> 8), UInt8(l)]) { result, c in result + [UInt8(c >> 8), UInt8(c)] }
        }
        
        return parameters.reduce([self.invokeApiMessage, UInt8(0)]) { result, keyValue in
            result + getStringBytes(keyValue.key) + getStringBytes(keyValue.value)
        } + [0, 0]
    }
    
    @objc private func resolveOnLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if let hitPoint = self.view.getHitPoint(recognizer: recognizer) {
            self.pressContinuation.yield((hitPoint, recognizer.state))
        }
    }
    
    @objc private func resolveOnTap(_ recognizer: UITapGestureRecognizer) {
        if let hitPoint = view.getHitPoint(recognizer: recognizer) {
            self.tapContinuation.yield(hitPoint)
        }
    }
    
    private func processFrameBufferUpdate(networkChannel: NetworkChannel) async throws -> Bool {
        let updater = StreamBufferUpdater(session: self, networkChannel: networkChannel)
        let result: Bool = try await updater.apply()
        return result
    }

    private func applyFrameBufferUpdate(frameData: Data) {
        let updater = SynchronousFrameBufferUpdater(session: self, frameUpdateData: frameData)
        
        do {
            try updater.apply()
        } catch {
            self.debug("Error while decoding frame data \(error)")
        }
    }
}

public enum FrameBufferViewError : Error {
    case UnsupportedRectangleEncoding
    case OutOfBounds
    case NoFrameBufferInfo
}

private struct SessionInfo {
    var networkChannel: NetworkChannel
    var task: Task<Void, Never>?
    var cancel: () -> Void
}

internal struct PixelFormat {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var	bigEndianFlag: UInt8
    var trueColorFlag: UInt8
    var redMax: UInt16
    var greenMax: UInt16
    var	blueMax: UInt16
    var	redShift: UInt8
    var	greenShift: UInt8
    var	blueShift: UInt8
    var	pad1: UInt8
    var	pad2: UInt8
    var	pad3: UInt8
}

internal struct FrameBufferInfo {
    var width: UInt16
    var height: UInt16
    var	pixelFormat: PixelFormat
    var nameLength: UInt32
    
    var size: CGSize { get { return CGSize(width: Int(width), height: Int(height)) } }
}

