//
//  Util.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 09/02/2020.
//  Copyright © 2020 Yuval Rakavy. All rights reserved.
//
import Foundation

public extension String.StringInterpolation {
    /// Represents a single numeric radix
    enum Radix: Int {
        case binary = 2, octal = 8, decimal = 10, hex = 16
        
        /// Returns a radix's optional prefix
        var prefix: String {
             return [.binary: "0b", .octal: "0o", .hex: "0x"][self, default: ""]
        }
    }
    
    /// Return padded version of the value using a specified radix
    mutating func appendInterpolation<I: BinaryInteger>(_ value: I, radix: Radix, prefix: Bool = false, toWidth width: Int = 0) {
        
        // Values are uppercased, producing `FF` instead of `ff`
        var string = String(value, radix: radix.rawValue).uppercased()
        
        // Strings are pre-padded with 0 to match target widths
        if string.count < width {
            string = String(repeating: "0", count: max(0, width - string.count)) + string
        }
        
        // Prefixes use lower case, sourced from `String.StringInterpolation.Radix`
        if prefix {
            string = radix.prefix + string
        }
        
        appendInterpolation(string)
    }
}

public class StopWatch {
    let name: String
    var total: clock_t
    var lapCount: Int
    var setPoint: clock_t?
    
    init(_ name: String) {
        self.name = name
        self.total = 0
        self.lapCount = 0
        self.setPoint = nil
    }
    
    public func start() {
        self.setPoint = clock()
    }
    
    func isRunning() -> Bool {
        setPoint != nil
    }
    
    public func stop() {
        if let setPoint = self.setPoint {
            let timeLap = clock() - setPoint
            self.total += timeLap
            self.lapCount += 1
        }
        else {
            NSLog("Stopwatch \(name) was stopped without starting it")
        }
    }
    
    public func reset() {
        self.total = 0
    }
    
    public func report(_ note: String? = nil) {
        if isRunning() {
            self.stop()
        }
        
        let totalInSeconds = Double(self.total) / Double(CLOCKS_PER_SEC)
        
        NSLog("Stopwatch \(self.name) \(note != nil ? " - \(note!) " : "") = \(totalInSeconds) seconds (\(lapCount) laps)")
    }
}
