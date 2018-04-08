//
//  PropertiesBytes.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 17/12/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation


extension Sequence where Iterator.Element == (key: String, value: String) {
    func packToBytes() -> [UInt8] {
        let result: [UInt8] = self.reduce([]) {(result, pair) in
            let propertyName = [UInt8](pair.key.utf8)
            let nameCountBytes = [UInt8(propertyName.count >> 8), UInt8(propertyName.count)]
            let propertyValue = [UInt8](pair.value.utf8)
            let valueCountBytes = [UInt8(propertyValue.count >> 8), UInt8(propertyValue.count)]
            
            return result + nameCountBytes + propertyName + valueCountBytes + propertyValue
            } + [0, 0]
        
        return result
    }
}

extension Collection where Iterator.Element == UInt8, Index == Int {
    func unpackProperties() -> [String: String] {
        var index = 0
        var result: [String:String] = [:]
        
        func getLength(at index: Self.Index) -> Int {
            return ((Int(self[index]) << 8) + Int(self[index+1]))
        }
        
        func getString(at i: Self.Index) -> (String?, Self.Index) {
            let length = getLength(at: i)
            let stringIndex = self.index(i, offsetBy: 2)
            var bytes: [UInt8] = []
            
            for b in stringIndex ..< self.index(stringIndex, offsetBy: length) {
                bytes.append(self[b])
            }
            
            return (String(bytes: bytes, encoding: String.Encoding.utf8), self.index(stringIndex, offsetBy: length))
        }
        
        while getLength(at: index) != 0 {
            var name: String?, value: String?
            
            (name, index) = getString(at: index)
            (value, index) = getString(at: index)
            
            if let n = name, let v = value {
                result[n] = v
            }
        }
        
        return result
    }
}
