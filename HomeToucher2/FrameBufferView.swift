//
//  FrameBufferView.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 02/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit

class FrameBufferView : UIView, FrameBitmapView {
    public var frameBuffer: UnsafeMutableBufferPointer<PixelType>?
    private var frameBufferImage: CGImage?
    private var frameBufferRect: CGRect?
    public var deviceShaken: PromisedQueue<Bool>?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = true
        self.becomeFirstResponder()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isUserInteractionEnabled = true
        self.becomeFirstResponder()
    }
    
    var isUsingRetinaDisplay: Bool {
        get { return self.contentScaleFactor > 1 }
    }
    
    public var lowRes: Bool = false
    
    var frameBounds: CGRect {
        get {
            
            return (self.isUsingRetinaDisplay && !self.lowRes) ?
                CGRect(x: self.bounds.origin.x * self.contentScaleFactor,
                       y: self.bounds.origin.y * self.contentScaleFactor,
                       width: self.bounds.size.width * self.contentScaleFactor,
                       height: self.bounds.size.height * self.contentScaleFactor) : self.bounds
        }
    }
    
    var frameSafeAreaInsets: UIEdgeInsets {
        get {
            let scale = self.lowRes ? 1 : self.contentScaleFactor
            
            if #available(iOS 11.0, *) {
                return UIEdgeInsets(top: self.safeAreaInsets.top * scale, left: self.safeAreaInsets.left * scale,
                                    bottom: self.safeAreaInsets.bottom * scale, right: self.safeAreaInsets.right * scale)
            } else {
                return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            }
        }
    }
    
    override func draw(_ rect: CGRect) {
        if let frameBufferImage = self.frameBufferImage, let context = UIGraphicsGetCurrentContext(), let frameBufferRect = self.frameBufferRect {
            context.translateBy(x: 0, y: self.bounds.size.height)
            
            if self.isUsingRetinaDisplay  && !self.lowRes {
                context.scaleBy(x: 1/self.contentScaleFactor, y: -1/self.contentScaleFactor)
            }
            else {
                context.scaleBy(x: 1, y: -1)
            }
            
            context.draw(frameBufferImage, in: frameBufferRect)
        }
    }
    
    // MARK: Implement FrameBitmapView protocol
    
    public func allocateFrameBitmap(size: CGSize) {
        self.freeFrameFrameBitmap()
        self.frameBufferRect = CGRect(x: (self.frameBounds.size.width - size.width) / 2,
                                      y: (self.frameBounds.size.height - size.height) / 2,
                                      width: size.width,
                                      height: size.height)
        
        let pixelCount = Int(size.height * size.width)
        
        self.frameBuffer = UnsafeMutableBufferPointer(start: UnsafeMutablePointer<PixelType>.allocate(capacity: pixelCount), count: pixelCount)
        
        let releaseDataCallback: CGDataProviderReleaseDataCallback = { _, data, size in }
        let dataProvider = CGDataProvider(dataInfo: nil, data: frameBuffer!.baseAddress!, size: pixelCount * MemoryLayout<PixelType>.size, releaseData: releaseDataCallback)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        
        self.frameBufferImage = CGImage(
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: dataProvider!,
            decode: nil,
            shouldInterpolate: false,
            intent: CGColorRenderingIntent.defaultIntent
        )
    }
    
    public func freeFrameFrameBitmap() {
        if let frameBuffer = self.frameBuffer {
            self.frameBufferImage = nil
            
            if let baseAddress = frameBuffer.baseAddress {
                baseAddress.deallocate()
            }
            
            self.frameBuffer = nil
        }
    }
    
    public var frameBitmap: UnsafeMutableBufferPointer<PixelType> {
        get {
            return self.frameBuffer!
        }
    }
    
    public func redisplay(rect: CGRect) {
        if let frameBufferRect = self.frameBufferRect {
            let rectangleToRedraw = self.isUsingRetinaDisplay ?
                CGRect(
                    x: (frameBufferRect.origin.x + rect.origin.x) / self.contentScaleFactor,
                    y: (frameBufferRect.origin.y + rect.origin.y) / self.contentScaleFactor,
                    width: rect.size.width / self.contentScaleFactor,
                    height: rect.size.height / self.contentScaleFactor
                ) : CGRect(
                    x: frameBufferRect.origin.x + rect.origin.x,
                    y: frameBufferRect.origin.y + rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
            )
            
            self.setNeedsDisplay(rectangleToRedraw)
        }
    }
    
    public func getHitPoint(recognizer: UIGestureRecognizer) -> CGPoint? {
        if let frameBufferRect = self.frameBufferRect {
            let hitPoint = recognizer.location(in: self)
            let scaleFactor = self.contentScaleFactor
            
            let result = self.isUsingRetinaDisplay ?
                CGPoint(x: (hitPoint.x - frameBufferRect.origin.x / scaleFactor) * scaleFactor, y: (hitPoint.y - frameBufferRect.origin.y / scaleFactor) * scaleFactor) :
                CGPoint(x: (hitPoint.x - frameBufferRect.origin.x), y: (hitPoint.y - frameBufferRect.origin.y))
            
            if result.x < frameBufferRect.size.width && result.y < frameBufferRect.size.height {
                return result
            }
        }
        
        return nil
    }
    
    override var canBecomeFirstResponder: Bool { get { return true } }
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        
        if motion == .motionShake {
            self.deviceShaken?.send(true)
        }
    }
}
