//
//  RemoteFrameBufferSession.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 25/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import PromiseKit

public typealias PixelType = UInt32

public protocol FrameBitmapView {
    func allocateFrameBitmap(size: CGSize)
    func freeFrameFrameBitmap()
    
    func redisplay(rect: CGRect)
    func getHitPoint(recognizer: UIGestureRecognizer) -> CGPoint?

    var frameBitmap: UnsafeMutableBufferPointer<PixelType> { get }
    var deviceShaken: PromisedQueue<Bool>? { get set }
}

public class RemoteFrameBufferSession {
    internal var model: HomeTouchModel
    internal var view: FrameBitmapView
    internal var frameBufferInfo: FrameBufferInfo?

    private let press = PromisedQueue<(hitPoint: CGPoint, state: UIGestureRecognizer.State)>("press")
    private let tap = PromisedQueue<CGPoint>("tap")
    private let cacheManager: CacheManager
    
    let debugLevel = 1
    
    let apiEncoding: Int32 = 102                  // Encoding used for API calls (fixed version, old encoding (100) is obsolite)
    let clientSideCachingEncoding: Int32 = 101    // Encoding used for client side caching
    
    let invokeApiMessage: UInt8 = 100
    let frameUpdateExtensionMessage: UInt8 = 101  // Message from server: frame update with length and hash (and optionally data)
    let sendFrameDataRequest: UInt8 = 101         // client asks server to send/drop frame update data
    
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
    }
    
    func debug(_ message: String, minDebugLevel: Int = 1) {
        if(self.debugLevel >= minDebugLevel) {
            NSLog(message)
        }
    }
    
    public func begin(server: String, port: Int, onSessionStarted: (() -> Void)? = nil) -> Promise<Bool> {
        debug("Starting RFB session")
        initializationStopwatch.start()
        
        func runSession(_ networkChannel: NetworkChannel) -> Promise<Bool> {
            let (cancellationPromise, cancel) = PromisedLand.getCancellationPromise()
            
            onSessionStarted?()
            
            let sessionPromise : Promise<Bool> = when(resolved:
                [
                    self.handleGestures(networkChannel: networkChannel, cancellationPromise: cancellationPromise),
                    self.handleServerInput(networkChannel: networkChannel, cancellationPromise: cancellationPromise)
                ]
            ).map { _ in
                    networkChannel.disconnect()
                    self.view.freeFrameFrameBitmap()
                    return true
            }
            
            self.activeSession = SessionInfo(networkChannel: networkChannel, sessionPromise: sessionPromise, cancel: cancel)
            return sessionPromise
        }
        
        return firstly {
            self.initSession(server: server, port: port)
        }.then(on: nil) { networkChannel in
            return runSession(networkChannel)
        }
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
            _ = self.activeSession?.networkChannel.sendToServer(dataItems: self.formatInvokeApiCommand(parameters: parameters))
        }
    }
    
    public var serverApiVersion: Int?
    
    private func initSession(server: String, port: Int) -> Promise<NetworkChannel> {
        let networkChannel = NetworkChannel(server: server, port: port)
        
        func sendUpdateRequestCommand() -> Promise<NetworkChannel> {
            debug("Sending frameUpdateRequest command", minDebugLevel: 2)
            return networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: false))
        }
        
        func getSessionName(_ frameBufferInfo: FrameBufferInfo) -> Promise<String> {
            return networkChannel.getFromServer(type: UInt8.self, count: Int(frameBufferInfo.nameLength)).map(on: nil) { (sessionNameBytes: [UInt8]) in
                return String(bytes: sessionNameBytes, encoding: String.Encoding.windowsCP1253) ?? "Cannot decode name"
            }
        }
        
        return networkChannel.connect().then(on: nil) { (_: NetworkChannel) -> Promise<NetworkChannel>  in
            self.doVersionHandshake(networkChannel)
        }.then(on: nil) { (_ : NetworkChannel) -> Promise<NetworkChannel>  in
            self.doSecurityHandshake(networkChannel)
        }.then(on: nil) { (_ : NetworkChannel) -> Promise<FrameBufferInfo> in
            networkChannel.getFromServer(type: FrameBufferInfo.self)
        }.then(on: nil) { (unfixedframeBufferInfo: FrameBufferInfo) -> Promise<String> in
            var frameBufferInfo: FrameBufferInfo = unfixedframeBufferInfo
            
            // Convert fields from network order to host order
            frameBufferInfo.height = frameBufferInfo.height.bigEndian
            frameBufferInfo.width = frameBufferInfo.width.bigEndian
            frameBufferInfo.nameLength = frameBufferInfo.nameLength.bigEndian
            frameBufferInfo.pixelFormat.redMax = frameBufferInfo.pixelFormat.redMax.bigEndian
            frameBufferInfo.pixelFormat.greenMax = frameBufferInfo.pixelFormat.greenMax.bigEndian
            frameBufferInfo.pixelFormat.blueMax = frameBufferInfo.pixelFormat.blueMax.bigEndian
            
            self.frameBufferInfo = frameBufferInfo
            self.view.allocateFrameBitmap(size: frameBufferInfo.size)
            
            return getSessionName(frameBufferInfo)
        }.then(on: nil) { (sessionName: String) -> Promise<NetworkChannel> in
            self.debug("RFB session name \(sessionName)")
            
            let encodingList = self.model.DisableCaching ?
                [
                    5,
                    0,
                    self.apiEncoding,
                ] :
                [
                    5,
                    0,
                    self.apiEncoding,
                    self.clientSideCachingEncoding
                ]


            return networkChannel.sendToServer(dataItems: self.formatSetEncodingCommand(supportedEncoding: encodingList))
        }.then(on: nil) { (_ : NetworkChannel) -> Promise<NetworkChannel> in
            sendUpdateRequestCommand()
        }.recover { err in
            Promise.init(error: err)
        }
    }
    
    private func doVersionHandshake(_ networkChannel: NetworkChannel) -> Promise<NetworkChannel> {
        return networkChannel.getFromServer(type: UInt8.self, count: 12).then(on: nil) { (serverVersionBytes: [UInt8]) -> Promise<NetworkChannel> in
            let version = [UInt8]("RFB 003.008\n".utf8)
            let serverVersion = String(bytes: serverVersionBytes, encoding: String.Encoding.utf8)!
            
            self.debug("Sever RFB version \(serverVersion)")
            
            return networkChannel.sendToServer(dataItems: version)
        }
    }
    
    private func doSecurityHandshake(_ networkChannel: NetworkChannel) -> Promise<NetworkChannel> {
        func handleSecurityResult(_ securityResult: UInt32) -> Promise<NetworkChannel> {
            return securityResult.bigEndian == 0 ?
                networkChannel.sendToServer(dataItem: UInt8(1)) :  // Send ClientInit (share flag is true)
                self.getErrorMessage(networkChannel: networkChannel).map(on: nil) {
                    errorMessage in
                        throw SessionError.SecurityFailed(errorMessage: errorMessage)
                }
        }
        
        return self.doGetAuthenticationMethods(networkChannel).then(on: nil) { (securityBytes: [UInt8]) -> Promise<NetworkChannel> in
            return networkChannel.sendToServer(dataItem: UInt8(1))      // No authentication
        }.then(on: nil) {_ in
            networkChannel.getFromServer(type: UInt32.self)
        }.then(on: nil) { (securityResult : UInt32) -> Promise<NetworkChannel> in
            handleSecurityResult(securityResult)
        }.recover { err in
            Promise.init(error: err)
        }
    }
    
    private func doGetAuthenticationMethods(_ networkChannel: NetworkChannel) -> Promise<[UInt8]> {
        func handleAuthenticationMethod(_ methodCount: UInt8) -> Promise<[UInt8]> {
            if methodCount > 0 {
                return networkChannel.getFromServer(type: UInt8.self, count: Int(methodCount))
            }
            else {
                return self.getErrorMessage(networkChannel: networkChannel).then(on: nil) { (errorMessage: String) -> Promise<[UInt8]> in
                    throw SessionError.InvalidConnection(errorMessage: errorMessage)
                }
            }
        }
        
        return firstly {
            networkChannel.getFromServer(type: UInt8.self)
        }.then(on: nil) { (methodCount: UInt8) -> Promise<[UInt8]> in
            return handleAuthenticationMethod(methodCount)
        }
    }
    
    private func getErrorMessage(networkChannel: NetworkChannel) -> Promise<String> {
        return networkChannel.getFromServer(type: UInt32.self).then(on: nil) {
            networkChannel.getFromServer(type: UInt8.self, count: Int($0.bigEndian))
        }.map {
            return String(bytes: $0, encoding: String.Encoding.utf8)!
        }
    }
    
    private func handleServerInput(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        initializationStopwatch.report()
        return PromisedLand.doWhile("handleServerInput", cancellationPromise: cancellationPromise) { return self.handleServerReply(networkChannel: networkChannel) }
    }
    
    private func handleServerReply(networkChannel: NetworkChannel) -> Promise<Bool> {
        func processReply(_ reply: UInt8) -> Promise<Bool> {
            switch reply {
                
            case 0:    // FrameBuffer update
                debug("Got frameBufferUpdate message from server", minDebugLevel: 2)
                return self.processFrameBufferUpdate(networkChannel: networkChannel).then(on: nil) {(_: Bool) -> Promise<NetworkChannel> in
                    // After done with updating, ask the server to send the next frame buffer update
                    self.debug("Send FrameUpdateRequestCommand (incremental: true)", minDebugLevel: 2)
                    return networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: true))
                }.map(on: nil) { (_: NetworkChannel) -> Bool in
                     true
                }
                
            case self.frameUpdateExtensionMessage:
                debug("Got frameBufferUpdateExtension message from server", minDebugLevel: 2)
                return self.processFrameUpdateExtension(networkChannel: networkChannel).then(on: nil) { (getFrameDataFromServer: Bool) -> Promise<NetworkChannel> in
                    if getFrameDataFromServer {
                        self.debug("Send SendFrameDataCommand)", minDebugLevel: 2)
                        return networkChannel.sendToServer(dataItems: self.formatSendFrameDataCommand())
                    }
                    else {
                        self.debug("Send FrameUpdateRequestCommand (incremental: true)", minDebugLevel: 2)
                        return networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: true))
                    }
                }.map(on: nil) { (_: NetworkChannel) in
                    true
                }
            
            case self.invokeApiMessage:
                debug("Got invoke API from server", minDebugLevel: 2)
                return self.processApiCall(networkChannel: networkChannel)
                
            default:
                return Promise<Bool>.value(false)
            }
        }
        
        return networkChannel.getFromServer(type: UInt8.self).then(on: nil) { (reply: UInt8) -> Promise<Bool> in
            return processReply(reply)
        }.recover { err in
            self.debug("handleServerReply - error -- calling self.terminate: \(err)")
            self.terminate()
            return Guarantee.value(false)
        }.then { r in return Promise.value(r) }
    }

    private func processFrameUpdateExtension(networkChannel: NetworkChannel) -> Promise<Bool> {
        return networkChannel.getFromServer(type: UInt8.self).then { (hasData: UInt8) -> Promise<Bool> in
            return networkChannel.getFromServer(type: UInt32.self, count: 2).then { (rawHeader: [UInt32]) -> Promise<(key: CacheKey, frameData: Data)?> in
                let cacheKey = CacheKey(length: rawHeader[0].bigEndian, hashCode: rawHeader[1].bigEndian)
                
                if hasData != 0 {
                    return networkChannel.getFromServer(count: Int(cacheKey.length)).then { (frameData: Data) -> Promise<(key: CacheKey, frameData: Data)?> in
                        self.cacheManager.add(key: cacheKey, frameData: frameData)
                        return Promise.value((key: cacheKey, frameData: frameData))
                    }
                }
                else {
                    let getDataFromCacheStopwatch = StopWatch("Get data from cache")
                    getDataFromCacheStopwatch.start()

                    if let frameData = self.cacheManager.get(key: cacheKey) {
                        getDataFromCacheStopwatch.report()
                        return Promise.value((key: cacheKey, frameData: frameData))
                    }
                    else {
                        getDataFromCacheStopwatch.stop()
                        return Promise.value(nil)
                    }
                }
            }.then { (keyAndFrameData: (key: CacheKey, frameData: Data)?) -> Promise<Bool> in
                if let k = keyAndFrameData {        // Got frame data either from cache or from the server
                    let applyFrameBufferUpdateStopwatch = StopWatch("ApplyFrameData")
                    
                    applyFrameBufferUpdateStopwatch.start()
                    self.applyFrameBufferUpdate(frameData: k.frameData)
                    applyFrameBufferUpdateStopwatch.report()
                    return Promise.value(false)     // No need for frame data
                }
                else {
                    return Promise.value(true)      // Need to get frame data
                }
            }
        }
    }
    
    private func receiveString(networkChannel: NetworkChannel) -> Promise<String?> {
        return networkChannel.getFromServer(type: UInt16.self).then { (count : UInt16) -> Promise<String?> in
            if count == 0 {
                return Promise.value(nil)
            }
            else {
                return networkChannel.getFromServer(type: UInt8.self, count: Int(count.bigEndian) * 2).then {
                    Promise.value(String(bytes: $0, encoding: String.Encoding.utf16BigEndian))
                }
            }
        }
    }
    
    typealias OptionalNameValuePair = (name: String, value: String)?
    
    private func receiveNameValue(networkChannel: NetworkChannel) -> Promise<OptionalNameValuePair> {
        return self.receiveString(networkChannel: networkChannel).then { (mayBeName : String?) -> Promise<OptionalNameValuePair> in
            if let name = mayBeName {
                return self.receiveString(networkChannel: networkChannel).then { (mayBeValue: String?) -> Promise<OptionalNameValuePair> in
                    if let value = mayBeValue {
                        return Promise.value((name: name, value: value))
                    }
                    else {
                        return Promise.value(nil)
                    }
                }
            }
            else {
                return Promise.value(nil)
            }
        }
    }
    
    private func processApiCall(networkChannel: NetworkChannel) -> Promise<Bool> {
        var dict = [String:String]()
        
        return networkChannel.getFromServer(type: UInt8.self).then(on: nil) { _ -> Promise<Bool> in
            Promise.value(true)
        }.then (on: nil) { _ -> Promise<Bool> in
            return PromisedLand.doWhile("processApiCall") {
                return self.receiveNameValue(networkChannel: networkChannel).map { maybeNameValuePair in
                    if let nameValuePair = maybeNameValuePair {
                        dict[nameValuePair.name] = nameValuePair.value
                        return true
                    }
                    else {
                        return false
                    }
                }
            }
        }.then { (_) -> Promise<Bool> in
            self.onApiCall?(dict)
            self.debug("ProcessApiCall returning Promise.value(true)")
            return Promise.value(true)
        }
    }
    
    private func handlePressGesture(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return PromisedLand.doWhile("handlePressGebture", cancellationPromise: cancellationPromise) { () in
            return self.press.wait().map(on: nil) { pressInfo in
                switch(pressInfo.state) {
                    
                case .began:
                    _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: true))
                    
                case .cancelled, .ended:
                    _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: false))
                
                default: break
                    
                }
                return true
            }
        }
    }
    
    private func handleTapGesture(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return PromisedLand.doWhile("handleTapGesture", cancellationPromise: cancellationPromise) { () in
            return self.tap.wait().map(on: nil) { hitPoint in
                self.debug("Send PointerEvent at \(hitPoint)", minDebugLevel: 2)
                _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: true))
                _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: false))
                
                return true
            }
        }
    }
    
    private func handleGestures(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return when(fulfilled:
            [
                handlePressGesture(networkChannel: networkChannel, cancellationPromise: cancellationPromise),
                handleTapGesture(networkChannel: networkChannel, cancellationPromise: cancellationPromise)
            ]
        ).map(on: nil) { _ in true }
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
            self.press.send((hitPoint, recognizer.state))
        }
    }
    
    @objc private func resolveOnTap(_ recognizer: UITapGestureRecognizer) {
        if let hitPoint = view.getHitPoint(recognizer: recognizer) {
            self.tap.send(hitPoint)
        }
    }
    
    private func processFrameBufferUpdate(networkChannel: NetworkChannel) -> Promise<Bool> {
        let updater = StreamBufferUpdater(session: self, networkChannel: networkChannel)
        
        return updater.apply()
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
    var sessionPromise: Promise<Bool>
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

