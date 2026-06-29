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
        var index = startIndex
        var result: [String:String] = [:]

        // Every read is bounds-checked: this parses a server-supplied byte stream,
        // and a truncated frame / oversized declared length / missing [0,0]
        // terminator must not walk past the end of the buffer (subscript trap).
        func getLength(at index: Int) -> Int? {
            guard index >= startIndex, index + 1 < endIndex else { return nil }
            return (Int(self[index]) << 8) + Int(self[index + 1])
        }

        func getString(at i: Int) -> (String?, Int)? {
            guard let length = getLength(at: i), length >= 0 else { return nil }
            let stringIndex = i + 2
            let endStringIndex = stringIndex + length
            guard stringIndex <= endIndex, endStringIndex <= endIndex else { return nil }

            var bytes: [UInt8] = []
            for b in stringIndex ..< endStringIndex {
                bytes.append(self[b])
            }

            return (String(bytes: bytes, encoding: String.Encoding.utf8), endStringIndex)
        }

        while let length = getLength(at: index), length != 0 {
            guard let (name, nameNext) = getString(at: index) else { break }
            index = nameNext
            guard let (value, valueNext) = getString(at: index) else { break }
            index = valueNext

            if let n = name, let v = value {
                result[n] = v
            }
        }

        return result
    }
}
