//
//  FrameUpdater.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 10/02/2020.
//  Copyright © 2020 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import PromiseKit

class FrameBufferUpdater {
    let session: RemoteFrameBufferSession
    let pixelFormat: PixelFormat
    let frameBufferInfo: FrameBufferInfo
    let frameBitmap: UnsafeMutableBufferPointer<PixelType>
    let rowOffset: Int
    
    init(session: RemoteFrameBufferSession) {
        self.session = session
        self.frameBufferInfo = session.frameBufferInfo!
        self.pixelFormat = self.frameBufferInfo.pixelFormat
        self.frameBitmap = session.view.frameBitmap
        self.rowOffset = Int(frameBufferInfo.width)
    }
    
    let toDevicePixelStopwatch = StopWatch("toDevicePixel")
    
    @inline(__always) func toDevicePixel(serverPixel: UInt32) -> UInt32 {
        toDevicePixelStopwatch.start()
        defer {
            toDevicePixelStopwatch.stop()
        }
        
        let r = (serverPixel >> UInt32(pixelFormat.redShift)) & UInt32(pixelFormat.redMax)
        let g = (serverPixel >> UInt32(pixelFormat.greenShift)) & UInt32(pixelFormat.greenMax)
        let b = (serverPixel >> UInt32(pixelFormat.blueShift)) & UInt32(pixelFormat.blueMax)
        
        return (b << 16) | (g << 8) | r
    }
    
    func fillSubrect(tileRectangle: CGRect, subrect: CGRect, color: PixelType) {
        let subRectOffset = (Int(tileRectangle.origin.y + subrect.origin.y)) * rowOffset + Int(tileRectangle.origin.x + subrect.origin.x)
        let subRectWidth = Int(subrect.size.width)
        var pFrameBitmap = frameBitmap.baseAddress?.advanced(by: subRectOffset)
         
        for _ in 0 ..< Int(subrect.size.height) {
            pFrameBitmap?.initialize(repeating: color, count: subRectWidth)
            pFrameBitmap = pFrameBitmap?.advanced(by: rowOffset)
        }
    }
}

class SynchronousFrameBufferUpdater : FrameBufferUpdater {
    let frameUpdateData: Data
    var index = 0;
    
    let getStopwatch = StopWatch("FrameBufferUpdater.get")
    let processTileStopwatch = StopWatch("processTile")
    let fillSubrectStopwatch = StopWatch("FillSubrect")
    let fillSubrectInnerLoopStopwatch = StopWatch("FillSubrect.innerLoop")
    
    public init(session: RemoteFrameBufferSession, frameUpdateData: Data) {
        self.frameUpdateData = frameUpdateData
        super.init(session: session)
    }
    
    public func apply() throws {
        let _:UInt8 = try get()     // Frame update command (0)
        let _:UInt8 = try get()     // Padding
        let rectCount = (try get() as UInt16).bigEndian

        NSLog("Enter SynchronousframeBufferUpdater with \(rectCount) rectangle")

        /* Uncomment to measure */
        /*
        getStopwatch.reset()
        processTileStopwatch.reset()
        fillSubrectStopwatch.reset()
        toDevicePixelStopwatch.reset()
        fillSubrectInnerLoopStopwatch.reset()
        */
        
        
        for _ in 0 ..< rectCount {
            try updateRectangle()
        }

        /*
        processTileStopwatch.report()
        fillSubrectStopwatch.report()
        fillSubrectInnerLoopStopwatch.report()
        getStopwatch.report()
        toDevicePixelStopwatch.report()
        */
    }

    private func updateRectangle() throws {
        let header: RFB_RectangleHeader = try get()
        
        switch header.encoding {
        case 0:
            try applyRawEncoding(header)
            
        case 5:
            try applyHextileEncoding(header)
            
        default:
            throw FrameBufferViewError.UnsupportedRectangleEncoding
        }
        
        session.view.redisplay(rect: header.rectangle)
    }
    
    private func applyRawEncoding(_ header: RFB_RectangleHeader) throws {
        let frameBitmap = session.view.frameBitmap
        
        if let frameBufferInfo = session.frameBufferInfo {
            let pixelsToGet = Int(header.height) * Int(header.width)
            
            if header.x == 0 && header.y == 0 && UInt16(header.width) == frameBufferInfo.width && UInt16(header.height) == frameBufferInfo.height {
                
                for i in 0 ..< pixelsToGet {
                    let serverPixel: UInt32 = try get()
                    frameBitmap[i] = toDevicePixel(serverPixel: serverPixel)
                }
            }
            else {
                var destinationOffet = header.y * Int(frameBufferInfo.width) + header.x
                
                for _ in 0 ..< header.height {
                    for i in 0 ..< header.width {
                        let serverPixel: UInt32 = try get()
                        frameBitmap[destinationOffet + i] = toDevicePixel(serverPixel: serverPixel)
                    }
                    destinationOffet += Int(frameBufferInfo.width)
                }
            }
        }
    }
    
    private func applyHextileEncoding(_ header: RFB_RectangleHeader) throws {
        let frameBitmap = session.view.frameBitmap
        let verticalTileCount = (header.height + 15) / 16
        let horizontalTileCount = (header.width + 15) / 16
        var forgroundColor: PixelType = 0
        var backgroundColor: PixelType = 0

        func processTile(_ tileRectangle: CGRect) throws {
            processTileStopwatch.start()
            defer { processTileStopwatch.stop() }
            
            let tileEncoding: UInt8 = try get()
            
            if (tileEncoding & 1) != 0 {    // Raw encoding
                var yOffset = Int(tileRectangle.origin.y) * Int(frameBufferInfo.width)

                for _ in 0 ..< Int(tileRectangle.size.height) {
                    var offset = yOffset + Int(tileRectangle.origin.x)
                    
                    for _ in 0 ..< Int(tileRectangle.size.width) {
                        let serverPixel: UInt32 = try get()
                        frameBitmap[offset] = toDevicePixel(serverPixel: serverPixel)
                        offset += 1
                    }
                    
                    yOffset += Int(frameBufferInfo.width)
                }
            }
            else {
                var subrectCount: UInt8 = 0
                
                if (tileEncoding & 2) != 0 {
                    let serverBackgroundColor: UInt32 = try get()
                    backgroundColor = toDevicePixel(serverPixel: serverBackgroundColor)
                }
                
                if (tileEncoding & 4) != 0 {
                    let serverForgroundColor: UInt32 = try get()
                    forgroundColor = toDevicePixel(serverPixel: serverForgroundColor)
                }
                
                if (tileEncoding & 8) != 0 {
                    subrectCount = try get()
                }
                
                let subrectAreColored = (tileEncoding & 16) != 0

                fillSubrect(tileRectangle: tileRectangle, subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)

                if subrectCount > 0 {
                    if subrectAreColored {
                        for _ in 0 ..< subrectCount {
                            let tileColoredSubrect: RFB_TileColoredSubrect = try get()
                            
                            fillSubrect(tileRectangle: tileRectangle, subrect: tileColoredSubrect.rectangle, color: toDevicePixel(serverPixel: tileColoredSubrect.color) )
                            
                        }
                    }
                    else {
                        for _ in 0 ..< subrectCount {
                            let tileSubrect: RFB_TileSubrect = try get()
                            
                            fillSubrect(tileRectangle: tileRectangle, subrect: tileSubrect.rectangle, color: forgroundColor)
                        }
                    }
                }
                else {
                    // All tile is in the same color (background color)
                    fillSubrect(tileRectangle: tileRectangle, subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)
                }
            }
        }
        
        for verticalTile in 0 ..< verticalTileCount {
            for horizontalTile in 0 ..< horizontalTileCount {
                let xOffset = CGFloat(horizontalTile)*16, yOffset = CGFloat(verticalTile)*16
                let x = CGFloat(header.x) + xOffset, y = CGFloat(header.y) + yOffset
                let tileRectangle = CGRect(x: x, y: y, width: min(16, CGFloat(header.width) - xOffset), height: min(16, CGFloat(header.height) - yOffset))

                try processTile(tileRectangle)
            }
        }
    }
    
    @inline(__always) func get<T>() throws -> T {
        getStopwatch.start()
        defer {
            getStopwatch.stop()
        }
        
        let nextIndex = index + MemoryLayout<T>.size
        
        guard nextIndex <= self.frameUpdateData.count else {
            throw FrameBufferViewError.OutOfBounds
        }

        let pResult = UnsafeMutablePointer<T>.allocate(capacity: 1)
        
        _ = withUnsafeMutableBytes(of: &pResult.pointee) { pDesination in
            self.frameUpdateData[index ..< nextIndex].withUnsafeBytes { pSource in
                pSource.copyBytes(to: pDesination)
            }
        }
        
        let result = pResult.pointee

        pResult.deallocate()
        index = nextIndex
        
        return result
    }
}

class StreamBufferUpdater : FrameBufferUpdater {
    let networkChannel: NetworkChannel
    
    init(session: RemoteFrameBufferSession, networkChannel: NetworkChannel) {
        self.networkChannel = networkChannel
        super.init(session: session)
    }
    
    
    public func apply() -> Promise<Bool> {
        return networkChannel.getFromServer(type: UInt8.self).then(on: nil) { (padding: UInt8) -> Promise<Bool> in
           Promise.value(true)
        }.then(on: nil) { _ -> Promise<Bool> in
            return self.networkChannel.getFromServer(type: UInt16.self).then(on: nil) {
                PromisedLand.loop(Int($0.bigEndian)) { _ in
                    return self.updateRectangle()
                }
            }
        }
    }
    
    private func updateRectangle() -> Promise<Bool> {
        return self.networkChannel.getFromServer(type: RFB_RectangleHeader.self).then(on: nil) { (header) -> Promise<Bool> in
            let processRectanglePromise: Promise<Bool>
            
            switch header.encoding {
                
            case 0:
                processRectanglePromise = self.processRawEncoding(header)
                
            case 5:
                processRectanglePromise = self.processHextileEncoding(header)
                
            default:
                throw FrameBufferViewError.UnsupportedRectangleEncoding
                
            }
            
            return processRectanglePromise.map(on: nil) { _ in
                self.session.view.redisplay(rect: header.rectangle)
                return true
            }
        }
    }
    
    private func processRawEncoding(_ header: RFB_RectangleHeader) -> Promise<Bool> {
        let frameBitmap = self.session.view.frameBitmap
        
        if let frameBufferInfo = self.session.frameBufferInfo {
            let pixelsToGet = Int(header.height) * Int(header.width)
           
            return networkChannel.getFromServer(type: UInt32.self, count: pixelsToGet).map(on: nil) { serverPixels in
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
                return true
            }
        }
        
        return Promise<Bool>.value(true)
    }
    
    private func processHextileEncoding(_ header: RFB_RectangleHeader) -> Promise<Bool> {
        let frameBitmap = self.session.view.frameBitmap
        let verticalTileCount = (header.height + 15) / 16
        let horizontalTileCount = (header.width + 15) / 16
        var forgroundColor: PixelType = 0
        var backgroundColor: PixelType = 0
        
        func processTile(_ tileRectangle: CGRect) -> Promise<Bool> {
           
            return networkChannel.getFromServer(type: UInt8.self).then(on: nil) { (tileEncoding : UInt8) -> Promise<Bool> in
                if (tileEncoding & 1) != 0 {        // Tile is in raw encoding
             
                    return self.networkChannel.getFromServer(type: UInt32.self, count: Int(tileRectangle.size.height) * Int(tileRectangle.size.width)).then(on: nil) { (tileContent: [UInt32]) -> Promise<Bool> in
                        var yOffset = Int(tileRectangle.origin.y) * Int(self.frameBufferInfo.width)
                        var tileContentIndex = 0
                        
                        for _ in 0 ..< Int(tileRectangle.size.height) {
                            var offset = yOffset + Int(tileRectangle.origin.x)
                            
                            for _ in 0 ..< Int(tileRectangle.size.width) {
                                frameBitmap[offset] = self.toDevicePixel(serverPixel: tileContent[tileContentIndex])
                                offset += 1
                                tileContentIndex += 1
                            }
                            
                            yOffset += Int(self.frameBufferInfo.width)
                        }
                        
                        return Promise.value(true)
                    }
                }
                else {
                    var bytesToGet = 0
                    
                    bytesToGet += (tileEncoding & 2) != 0 ? MemoryLayout<UInt32>.size : 0       // Background color given
                    bytesToGet += (tileEncoding & 4) != 0 ? MemoryLayout<UInt32>.size : 0       // Forground color given
                    bytesToGet += (tileEncoding & 8) != 0 ? MemoryLayout<UInt8>.size : 0        // Subrect count
                    
                    let subrectAreColored = (tileEncoding & 16) != 0
                    
                    return self.networkChannel.getFromServer(type: UInt8.self, count: bytesToGet).then(on: nil) { (tileData : [UInt8]) -> Promise<Bool> in
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
                        
                        self.fillSubrect(tileRectangle: tileRectangle, subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)
                        
                        if subrectCount > 0 {
                            if(subrectAreColored) {
                                return self.networkChannel.getFromServer(type: RFB_TileColoredSubrect.self, count: Int(subrectCount)).map(on: nil) { (subrects: [RFB_TileColoredSubrect]) -> Bool in
                                    for subrect in subrects {
                                        self.fillSubrect(tileRectangle: tileRectangle, subrect: subrect.rectangle, color: self.toDevicePixel(serverPixel: subrect.color))
                                    }
                                    
                                    return true
                                }
                            }
                            else {
                                return self.networkChannel.getFromServer(type: RFB_TileSubrect.self, count: Int(subrectCount)).map(on: nil) { (subrects : [RFB_TileSubrect]) -> Bool in
                                    for subrect in subrects {
                                        self.fillSubrect(tileRectangle: tileRectangle, subrect: subrect.rectangle, color: forgroundColor)
                                    }
                                    
                                    return true
                                }
                            }
                        }
                        else {
                            // All the tile is in the same color (background color)
                            self.fillSubrect(tileRectangle: tileRectangle, subrect: CGRect(origin: CGPoint(x: 0, y: 0), size: tileRectangle.size), color: backgroundColor)
                            return Promise.value(true)
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
                
                return processTile(tileRectangle)
            }
        }
    }
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

