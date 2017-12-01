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
    private var view: FrameBitmapView
    private var frameBufferInfo: FrameBufferInfo?

    private let press = PromisedQueue<(hitPoint: CGPoint, state: UIGestureRecognizerState)>()
    private let tap = PromisedQueue<CGPoint>()
    
    let apiEncoding: Int32 = 100           // Encoding used for API calls
    
    private var onPress: ((CGPoint, UIGestureRecognizerState) -> Void)?
    private var onTap: ((_ hitPoint: CGPoint) -> Void)?
    
    private var activeSession: SessionInfo?
    
    init(frameBitmapView: FrameBitmapView) {
        self.view = frameBitmapView
        self.activeSession = nil
        self.serverApiVersion = nil
    }
    
    public func begin(server: String, port: Int, onSessionStarted: (() -> Void)? = nil) -> Promise<Bool> {
        NSLog("Starting RFB session")
        
        return firstly {
            self.initSession(server: server, port: port)
        }.then(on: zalgo) { networkChannel in
            let (cancellationPromise, cancel) = PromisedLand.getCancellationPromise()
            
            onSessionStarted?()
            
            let sessionPromise = when(resolved:
                [
                    self.handleGestures(networkChannel: networkChannel, cancellationPromise: cancellationPromise),
                    self.handleServerInput(networkChannel: networkChannel, cancellationPromise: cancellationPromise)
                ]
            ).always {
                networkChannel.disconnect()
                self.view.freeFrameFrameBitmap()
            }.then(on: zalgo) { _ in true }
            
            self.activeSession = SessionInfo(networkChannel: networkChannel, sessionPromise: sessionPromise, cancel: cancel)
            return sessionPromise
        }
    }
    
    public func terminate() {
        NSLog("RFBsession.terminate")
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
            _ = self.activeSession?.networkChannel.sendToServer(dataItems: self.formatInvokeApiCommand(parameters: parameters))
        }
    }
    
    public var serverApiVersion: Int?
    
    private func initSession(server: String, port: Int) -> Promise<NetworkChannel> {
        let networkChannel = NetworkChannel(server: server, port: port)
        
        return firstly {
            networkChannel.connect()
        }.then {_ in 
            self.doVersionHandshake(networkChannel)
        }.then(on: zalgo) {_ in
            self.doSecurityHandshake(networkChannel)
        }.then(on: zalgo) {_ in 
            networkChannel.getFromServer(type: FrameBufferInfo.self)
        }.then(on: zalgo) { (unfixedframeBufferInfo: FrameBufferInfo) in
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
            
            return networkChannel.getFromServer(type: UInt8.self, count: Int(frameBufferInfo.nameLength)).then(on: zalgo) { (sessionNameBytes: [UInt8]) in
                let sessionName = String(bytes: sessionNameBytes, encoding: String.Encoding.windowsCP1253) ?? "Cannot decode name"
                
                NSLog("RFB session name \(sessionName)")
                return networkChannel.sendToServer(dataItems: self.formatSetEncodingCommand(supportedEncoding: [0, 5 , self.apiEncoding]))     // Raw and Hextile encoding are supported
            }
        }.then(on: zalgo) { (_:NetworkChannel) in
            networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: false))
        }
    }
    
    private func doVersionHandshake(_ networkChannel: NetworkChannel) -> Promise<NetworkChannel> {
        return networkChannel.getFromServer(type: UInt8.self, count: 12).then(on: zalgo) { serverVersionBytes in
            let version = [UInt8]("RFB 003.008\n".utf8)
            let serverVersion = String(bytes: serverVersionBytes, encoding: String.Encoding.utf8)!
            
            NSLog("Sever RFB version \(serverVersion)")
            
            return networkChannel.sendToServer(dataItems: version)
        }
    }
    
    private func doSecurityHandshake(_ networkChannel: NetworkChannel) -> Promise<NetworkChannel> {
        return firstly {
            self.doGetAuthenticationMethods(networkChannel)
        }.then(on: zalgo) { (securityBytes: [UInt8]) in
            return networkChannel.sendToServer(dataItem: UInt8(1))      // No authentication
        }.then(on: zalgo) {_ in 
            networkChannel.getFromServer(type: UInt32.self)
        }.then(on: zalgo) { (securityResult) -> Promise<NetworkChannel> in
            securityResult.bigEndian == 0 ?
                networkChannel.sendToServer(dataItem: UInt8(1)) :  // Send ClientInit (share flag is true)
                self.getErrorMessage(networkChannel: networkChannel).then(on: zalgo) { throw SessionError.SecurityFailed(errorMessage: $0) }
        }
    }
    
    private func doGetAuthenticationMethods(_ networkChannel: NetworkChannel) -> Promise<[UInt8]> {
        return firstly {
            networkChannel.getFromServer(type: UInt8.self)
        }.then(on: zalgo) {
            $0 > 0 ? networkChannel.getFromServer(type: UInt8.self, count: Int($0)) :
                self.getErrorMessage(networkChannel: networkChannel).then(on: zalgo) { throw SessionError.InvalidConnection(errorMessage: $0) }
        }
    }
    
    private func getErrorMessage(networkChannel: NetworkChannel) -> Promise<String> {
        return networkChannel.getFromServer(type: UInt32.self).then(on: zalgo) {
            networkChannel.getFromServer(type: UInt8.self, count: Int($0.bigEndian))
        }.then {
            String(bytes: $0, encoding: String.Encoding.utf8)!
        }
    }
    
    private func handleServerInput(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return PromisedLand.doWhile(cancellationPromise: cancellationPromise) { return self.handleServerReply(networkChannel: networkChannel) }
    }
    
    private func handleServerReply(networkChannel: NetworkChannel) -> Promise<Bool> {
        return networkChannel.getFromServer(type: UInt16.self).then(on: zalgo) {
            let replyType = $0.bigEndian
            
            if replyType == 0 {    // FrameBuffer update
                return self.processFrameBufferUpdate(networkChannel: networkChannel).then(on: zalgo) {_ in
                    // After done with updating, ask the server to send the next frame buffer update
                    return networkChannel.sendToServer(dataItems: self.formatFrameBufferUpdateRequstCommand(incremental: true))
                }.then(on: zalgo) { (_: NetworkChannel) in
                    true
                }
            }
            else if replyType == UInt16(self.apiEncoding) {
                return self.processApiCall(networkChannel: networkChannel)
            }
            else{
                return Promise<Bool>(value: false)
            }
        }.catch { _ in
            NSLog("handleServerReply - error -- calling self.terminate")
            self.terminate()
        }
    }

    private func receiveString(networkChannel: NetworkChannel) -> Promise<String?> {
        return networkChannel.getFromServer(type: UInt16.self).then { count in
            if count == 0 {
                return Promise(value: nil)
            }
            else {
                return networkChannel.getFromServer(type: UInt8.self, count: Int(count.bigEndian) * 2).then {
                    Promise(value: String(bytes: $0, encoding: String.Encoding.utf16BigEndian))
                }
            }
        }
    }
    
    private func receiveNameValue(networkChannel: NetworkChannel) -> Promise<(name: String, value: String)?> {
        return self.receiveString(networkChannel: networkChannel).then { mayBeName in
            if let name = mayBeName {
                return self.receiveString(networkChannel: networkChannel).then { mayBeValue in
                    if let value = mayBeValue {
                        return Promise(value: (name: name, value: value))
                    }
                    else {
                        return Promise(value: nil)
                    }
                }
            }
            else {
                return Promise(value: nil)
            }
        }
    }
    
    private func processApiCall(networkChannel: NetworkChannel) -> Promise<Bool> {
        var dict = [String:String]()
        
        return PromisedLand.doWhile {
            return self.receiveNameValue(networkChannel: networkChannel).then { maybeNameValuePair in
                if let nameValuePair = maybeNameValuePair {
                    dict[nameValuePair.name] = nameValuePair.value
                    return Promise(value: true)
                }
                else {
                    return Promise(value: false)
                }
            }
        }.then { _ in
            self.onApiCall?(dict)
            return Promise(value: true)
        }
    }
    
    private func handlePressGesture(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return PromisedLand.doWhile(cancellationPromise: cancellationPromise) { () in
            return self.press.wait().then(on: zalgo) { pressInfo in
                switch(pressInfo.state) {
                    
                case .began:
                    _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: true))
                    
                case .cancelled, .ended:
                    _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: pressInfo.hitPoint, buttonDown: false))
                
                default: break
                    
                }
                return Promise(value: true)
            }
        }
    }
    
    private func handleTapGesture(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return PromisedLand.doWhile(cancellationPromise: cancellationPromise) { () in
            return self.tap.wait().then(on: zalgo) { hitPoint in
                _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: true))
                _ = networkChannel.sendToServer(dataItems: self.formatPointerEvent(hitPoint: hitPoint, buttonDown: false))
                
                return Promise(value: true)
            }
        }
    }
    
    private func handleGestures(networkChannel: NetworkChannel, cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        return when(fulfilled:
            [
                handlePressGesture(networkChannel: networkChannel, cancellationPromise: cancellationPromise),
                handleTapGesture(networkChannel: networkChannel, cancellationPromise: cancellationPromise)
            ]
        ).then(on: zalgo) { _ in true }
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
        
        return parameters.reduce([UInt8(apiEncoding), UInt8(0)]) { result, keyValue in
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
    
    // MARK: Process frame buffer rectangle update
    
    private func processFrameBufferUpdate(networkChannel: NetworkChannel) -> Promise<Bool> {
        return networkChannel.getFromServer(type: UInt16.self).then(on: zalgo) {
            PromisedLand.loop(Int($0.bigEndian)) { _ in
                return self.updateRectangle(networkChannel)
            }
        }
    }
    
    private func updateRectangle(_ networkChannel: NetworkChannel) -> Promise<Bool> {
        return networkChannel.getFromServer(type: RFB_RectangleHeader.self).then(on: zalgo) { (header) -> Promise<Bool> in
            let processRectanglePromise: Promise<Bool>
            
            switch header.encoding {
                
            case 0:
                processRectanglePromise = self.processRawEncoding(networkChannel, header)
                
            case 5:
                processRectanglePromise = self.processHextileEncoding(networkChannel, header)
                
            default:
                throw FrameBufferViewError.UnsupportedRectangleEncoding
                
            }
            
            return processRectanglePromise.then(on: zalgo) { _ in
                self.view.redisplay(rect: header.rectangle)
                return Promise<Bool>(value: true)
            }
        }
    }
    
    private func processRawEncoding(_ networkChannel: NetworkChannel, _ header: RFB_RectangleHeader) -> Promise<Bool> {
        let frameBitmap = self.view.frameBitmap
        
        if let frameBufferInfo = self.frameBufferInfo {
            let pixelsToGet = Int(header.height) * Int(header.width)
           
            return networkChannel.getFromServer(type: UInt32.self, count: pixelsToGet).then(on: zalgo) { serverPixels in
                // Check for special case where the update is for the whole buffer
                if header.x == 0 && header.y == 0 && UInt16(header.width) == frameBufferInfo.width && UInt16(header.height) == frameBufferInfo.height {
                    for index in 0 ..< pixelsToGet {
                        frameBitmap[index] = self.toDevicePixel(serverPixel: serverPixels[index])
                    }
                }
                else {
                    var destinationOffset = header.y * Int(frameBufferInfo.width) + header.x
                    var sourceOffset = 0
                    
                    for _ in 0 ..< header.height {
                        for index in 0 ..< header.width {
                            frameBitmap[destinationOffset + index] = self.toDevicePixel(serverPixel: serverPixels[sourceOffset + index])
                        }
                        
                        sourceOffset += header.width
                        destinationOffset += Int(frameBufferInfo.width)
                    }
                    
                }
                return Promise<Bool>(value: true)
            }
        }
        
        return Promise<Bool>(value: true)
    }
    
    private func processHextileEncoding(_ networkChannel: NetworkChannel, _ header: RFB_RectangleHeader) -> Promise<Bool> {
        guard let frameBufferInfo = frameBufferInfo else{
            return Promise<Bool>(value: false)
        }
        
        let frameBitmap = self.view.frameBitmap
        let verticalTileCount = (header.height + 15) / 16
        let horizontalTileCount = (header.width + 15) / 16
        var forgroundColor: PixelType = 0
        var backgroundColor: PixelType = 0
        
        func processTile(_ networkChannel: NetworkChannel, _ tileRectangle: CGRect) -> Promise<Bool> {
            
            func fillSubrect(subrect: CGRect, color: PixelType) {
                var yOffset = (Int(tileRectangle.origin.y + subrect.origin.y)) * Int(frameBufferInfo.width)
                
                for _ in 0 ..< Int(subrect.size.height) {
                    var offset = yOffset + Int(tileRectangle.origin.x + subrect.origin.x)
                    
                    for _ in 0 ..< Int(subrect.size.width) {
                        frameBitmap[offset] = color
                        offset += 1
                    }
                    
                    yOffset += Int(frameBufferInfo.width)
                }
            }
            
            return networkChannel.getFromServer(type: UInt8.self).then(on: zalgo) { tileEncoding in
                if (tileEncoding & 1) != 0 {        // Tile is in raw encoding
             
                    return networkChannel.getFromServer(type: UInt32.self, count: Int(tileRectangle.size.height) * Int(tileRectangle.size.width)).then(on: zalgo) { tileContent in
                        var yOffset = Int(tileRectangle.origin.y) * Int(frameBufferInfo.width)
                        var tileContentIndex = 0
                        
                        for _ in 0 ..< Int(tileRectangle.size.height) {
                            var offset = yOffset + Int(tileRectangle.origin.x)
                            
                            for _ in 0 ..< Int(tileRectangle.size.width) {
                                frameBitmap[offset] = self.toDevicePixel(serverPixel: tileContent[tileContentIndex])
                                offset += 1
                                tileContentIndex += 1
                            }
                            
                            yOffset += Int(frameBufferInfo.width)
                        }
                        
                        return Promise<Bool>(value: true)
                    }
                }
                else {
                    var bytesToGet = 0
                    
                    bytesToGet += (tileEncoding & 2) != 0 ? MemoryLayout<UInt32>.size : 0       // Background color given
                    bytesToGet += (tileEncoding & 4) != 0 ? MemoryLayout<UInt32>.size : 0       // Forground color given
                    bytesToGet += (tileEncoding & 8) != 0 ? MemoryLayout<UInt8>.size : 0        // Subrect count
                    
                    let subrectAreColored = (tileEncoding & 16) != 0
                    
                    return networkChannel.getFromServer(type: UInt8.self, count: bytesToGet).then(on: zalgo) { tileData in
                        var subrectCount: UInt8 = 0
                        
                        tileData.withUnsafeBufferPointer { pTileData in
                            if let p = UnsafeRawPointer(pTileData.baseAddress) {
                                var offset = 0
                                
                                if (tileEncoding & 2) != 0 {
                                    backgroundColor = self.toDevicePixel(serverPixel: p.load(fromByteOffset: offset, as: UInt32.self))
                                    offset += MemoryLayout<UInt32>.size
                                }
                                
                                if (tileEncoding & 4) != 0 {
                                    forgroundColor = self.toDevicePixel(serverPixel: p.load(fromByteOffset: offset, as: UInt32.self))
                                    offset += MemoryLayout<UInt32>.size
                                }
                                
                                if (tileEncoding & 8) != 0 {
                                    subrectCount = p.load(fromByteOffset: offset, as: UInt8.self)
                                    offset += MemoryLayout<UInt8>.size
                                }
                            }
                        }
                        
                        fillSubrect(subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)
                        
                        if subrectCount > 0 {
                            if(subrectAreColored) {
                                return networkChannel.getFromServer(type: RFB_TileColoredSubrect.self, count: Int(subrectCount)).then(on: zalgo) { subrects in
                                    for subrect in subrects {
                                        fillSubrect(subrect: subrect.rectangle, color: self.toDevicePixel(serverPixel: subrect.color))
                                    }
                                    
                                    return Promise<Bool>(value: true)
                                }
                            }
                            else {
                                return networkChannel.getFromServer(type: RFB_TileSubrect.self, count: Int(subrectCount)).then(on: zalgo) { subrects in
                                    for subrect in subrects {
                                        fillSubrect(subrect: subrect.rectangle, color: forgroundColor)
                                    }
                                    
                                    return Promise<Bool>(value: true)
                                }
                            }
                        }
                        else {
                            // All the tile is in the same color (background color)
                            fillSubrect(subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)
                            return Promise<Bool>(value: true)
                        }
                        
                    }
                }
            }
        }
        
        return PromisedLand.loop(verticalTileCount) { verticalTile in
            return PromisedLand.loop(horizontalTileCount) { horizontalTile in
                let xOffset = CGFloat(horizontalTile)*16, yOffset = CGFloat(verticalTile)*16
                let x = CGFloat(header.x) + xOffset, y = CGFloat(header.y) + yOffset
                let tileRectangle = CGRect(x: x, y: y, width: min(16, CGFloat(header.width) - xOffset), height: min(16, CGFloat(header.height) - yOffset))
                
                return processTile(networkChannel, tileRectangle)
            }
        }
    }
    
    private func toDevicePixel(serverPixel: UInt32) -> UInt32 {
        if let pixelFormat = self.frameBufferInfo?.pixelFormat {
            let r = (serverPixel >> UInt32(pixelFormat.redShift)) & UInt32(pixelFormat.redMax)
            let g = (serverPixel >> UInt32(pixelFormat.greenShift)) & UInt32(pixelFormat.greenMax)
            let b = (serverPixel >> UInt32(pixelFormat.blueShift)) & UInt32(pixelFormat.blueMax)
            
            return (b << 16) | (g << 8) | r
            
        }
        
        return 0;
    }
}

public enum FrameBufferViewError : Error {
    case UnsupportedRectangleEncoding
}

private struct SessionInfo {
    var networkChannel: NetworkChannel
    var sessionPromise: Promise<Bool>
    var cancel: () -> Void
}

private struct PixelFormat {
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

private struct FrameBufferInfo {
    var width: UInt16
    var height: UInt16
    var	pixelFormat: PixelFormat
    var nameLength: UInt32
    
    var size: CGSize { get { return CGSize(width: Int(width), height: Int(height)) } }
}

private struct RFB_TileSubrect : TileSubrect {
    var xyPosition: UInt8
    var widthHeight: UInt8
}

private struct RFB_TileColoredSubrect: TileSubrect {
    // 4 UInt8 are used instead of UInt32 to avoid Swift aligning elements on 4 bytes boundries in which array of subrects is no layed out as the data
    // received from the server
    var color1: UInt8
    var color2: UInt8
    var color3: UInt8
    var color4: UInt8
    var xyPosition: UInt8
    var widthHeight: UInt8
    
    var color: UInt32 {
        get {
            let c4 = UInt32(color4) << 24
            let c3 = UInt32(color3) << 16
            let c2 = UInt32(color2) << 8
            let c1 = UInt32(color1)
            
            return c4 | c3 | c2 | c1
//            return UInt32((UInt32(color4) << 24) | (UInt32(color3) << 16) | (UInt32(color2) << 8) | UInt32(color1))
        }
    }
}

private protocol TileSubrect {
    var xyPosition: UInt8 { get }
    var widthHeight: UInt8 { get }
}

private extension TileSubrect {
    var x: Int { get { return Int((xyPosition >> 4) & 0x0f) } }
    var y: Int { get { return Int(xyPosition & 0x0f) } }
    
    var width: Int { get { return Int((widthHeight >> 4) & 0x0f) + 1 } }
    var height: Int { get { return Int(widthHeight & 0x0f) + 1 } }
    
    var rectangle: CGRect { get { return CGRect(x: self.x, y: self.y, width: self.width, height: self.height) } }
}

private struct RFB_RectangleHeader {
    private var _x: UInt16
    private var _y: UInt16
    private var _width: UInt16
    private var _height: UInt16
    private var _encoding: Int32
    
    var x: Int { get { return Int(_x.bigEndian) } }
    var y: Int { get { return Int(_y.bigEndian) } }
    var width: Int { get { return Int(_width.bigEndian) } }
    var height: Int { get { return Int(_height.bigEndian) } }
    var encoding: Int { get { return Int(_encoding.bigEndian) } }
    var rectangle: CGRect { get { return CGRect(x: x, y:y, width: width, height: height) } }
}
