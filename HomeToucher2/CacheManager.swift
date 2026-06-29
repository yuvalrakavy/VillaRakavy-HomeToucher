//
//  cacheManager.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 06/02/2020.
//  Copyright © 2020 Yuval Rakavy. All rights reserved.
//

import Foundation

public struct CacheKey : Hashable{
    var length: UInt32
    var hashCode: UInt32
}

struct CacheKeyFileEntry {
    var cacheKey: CacheKey
    var dataOffset: UInt32
}

enum CacheError: Error {
    case CannotCreateKeyFile
    case CannotCreateDataFile
    case KeyfileNotFound
    case DataFileNotFound
    case InvalidCacheVersion
}

let cacheVersion: UInt32 = 1

public class CacheManager {
    var cacheMap: [CacheKey: UInt32]
    let keyFile: FileHandle
    let dataFile: FileHandle
    
    init() throws {
        var aKeyFile: FileHandle?
        self.cacheMap = Dictionary()
        
        let cacheFolder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let keyFileUrl = cacheFolder.appendingPathComponent("FrameUpdates.keys")
        let dataFileUrl = cacheFolder.appendingPathComponent("FrameUpdates.data")
       
        aKeyFile = FileHandle(forUpdatingAtPath: keyFileUrl.path)
            
        if aKeyFile == nil {
            let versionData = withUnsafeBytes(of: cacheVersion) { Data($0) }
            
            if(!FileManager.default.createFile(atPath: keyFileUrl.path, contents: versionData, attributes: nil)) {
                throw CacheError.CannotCreateKeyFile
            }
            
            if let aKeyFile = FileHandle(forUpdatingAtPath: keyFileUrl.path) {
                self.keyFile = aKeyFile
            }
            else {
                throw CacheError.KeyfileNotFound
            }
        }
        else {
            self.keyFile = aKeyFile!
        }

        self.keyFile.seek(toFileOffset: 0)
        let keyFileData = self.keyFile.readDataToEndOfFile()

        let headerSize = MemoryLayout<UInt32>.size
        let entrySize = MemoryLayout<CacheKeyFileEntry>.size

        // The cache is disposable. A truncated/corrupt key file (e.g. from a prior
        // crash mid-write) must RESET it, never trap (load(as:) past end /
        // copyBytes overflow) and never throw (which would fatalError in the
        // controller's init).
        let keyFileVersion: UInt32 = keyFileData.count >= headerSize
            ? keyFileData.withUnsafeBytes { $0.load(as: UInt32.self) }
            : 0

        if keyFileVersion == cacheVersion {
            // Parse only WHOLE entries; ignore any partial trailing entry so the
            // copy can never exceed the destination buffer.
            let keyFileEntryCount = max(0, (keyFileData.count - headerSize) / entrySize)
            let bytesToCopy = keyFileEntryCount * entrySize

            if keyFileEntryCount > 0 {
                let keyFileEntries = keyFileData.withUnsafeBytes { pKeyFileData in
                    Array<CacheKeyFileEntry>(unsafeUninitializedCapacity: keyFileEntryCount) {  pKeyFileEntris, nElement in
                        nElement = keyFileEntryCount
                        pKeyFileData.copyBytes(to: pKeyFileEntris, from: headerSize ..< (headerSize + bytesToCopy))
                    }
                }

                for keyFileEntry in keyFileEntries {
                    cacheMap[keyFileEntry.cacheKey] = keyFileEntry.dataOffset
                }
            }
        } else {
            // Wrong/old/corrupt version: reset the key file to a clean state.
            NSLog("Cache key file invalid (version \(keyFileVersion), \(keyFileData.count) bytes); resetting")
            self.keyFile.truncateFile(atOffset: 0)
            self.keyFile.seek(toFileOffset: 0)
            self.keyFile.write(withUnsafeBytes(of: cacheVersion) { Data($0) })
            self.keyFile.synchronizeFile()
        }

        let aDataFile = FileHandle(forUpdatingAtPath: dataFileUrl.path)
        
        if aDataFile == nil {
            let versionData = withUnsafeBytes(of: cacheVersion) { Data($0) }

            if(!FileManager.default.createFile(atPath: dataFileUrl.path, contents: versionData, attributes: nil)) {
                throw CacheError.CannotCreateDataFile
            }
            
            if let aDataFile = FileHandle(forUpdatingAtPath: dataFileUrl.path) {
                self.dataFile = aDataFile
            }
            else {
                throw CacheError.DataFileNotFound
            }
        }
        else {
            self.dataFile = aDataFile!
        }
        
        dataFile.seek(toFileOffset: 0)
        let dataFileVersion = dataFile.readData(ofLength: MemoryLayout<UInt32>.size).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        if(dataFileVersion != cacheVersion) {
            throw CacheError.InvalidCacheVersion
        }
        
        let info = self.getInfo()
        NSLog("Cache has \(info.nItems) entries, size is \(info.cacheSize) bytes")
    }
    
    
    public func add(key: CacheKey, frameData: Data) {
        NSLog("Adding frame data with \(key.length) bytes, hash \(key.hashValue, radix: .hex)")
        dataFile.seekToEndOfFile()
        keyFile.seekToEndOfFile()
        
        let keyFileEntry = CacheKeyFileEntry(cacheKey: key, dataOffset: UInt32(dataFile.offsetInFile))
        let keyFileEntryData = withUnsafeBytes(of: keyFileEntry) { Data($0) }
        
        keyFile.write(keyFileEntryData)
        dataFile.write(frameData)
        
        keyFile.synchronizeFile()
        dataFile.synchronizeFile()
        
        cacheMap[key] = keyFileEntry.dataOffset
    }
    
    public func get(key: CacheKey) -> Data? {
        if let dataOffset = cacheMap[key] {
            NSLog("Get frame data from cache with \(key.length) bytes, hash \(key.hashValue, radix: .hex)")
            dataFile.seek(toFileOffset: UInt64(dataOffset))
            return dataFile.readData(ofLength: Int(key.length))
        }
        
        return nil
    }

    public func getInfo() -> (nItems: Int, cacheSize: UInt32) {
        dataFile.seekToEndOfFile()
        return (nItems: cacheMap.count, cacheSize: UInt32(dataFile.offsetInFile))
    }
    
    public func clearCache() {
        keyFile.truncateFile(atOffset: 0)
        dataFile.truncateFile(atOffset: 0)
        
        let versionData = withUnsafeBytes(of: cacheVersion) { Data($0) }

        keyFile.write(versionData)
        dataFile.write(versionData)
        
        keyFile.synchronizeFile()
        dataFile.synchronizeFile()
        
        cacheMap.removeAll()
    }
}
