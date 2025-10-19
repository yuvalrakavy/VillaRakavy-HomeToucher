//
//  PromiseExtensions.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 02/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

// Useful Promise functions

import Foundation

class PromisedLand {
    // Async doWhile: repeatedly executes body while it returns true
    public static func doWhile(_ optionalTitle: String? = nil, _ body: @escaping () async throws -> Bool) async rethrows -> Bool {
        while try await body() { }
        return true
    }

    // Async doWhile with cancellation via a Bool-producing async closure
    public static func doWhile(_ optionalTitle: String? = nil, cancellation: @escaping () async -> Bool, _ body: @escaping () async throws -> Bool) async rethrows -> Bool {
        while true {
            if await cancellation() { return true }
            let shouldContinue = try await body()
            if !shouldContinue { return true }
        }
    }
}

actor CancellationBox {
    private var cancelled = false
    func cancel() { cancelled = true }
    func isCancelled() -> Bool { cancelled }
}

extension PromisedLand {
    struct CancellationHandle {
        fileprivate let box: CancellationBox
        func cancel() { Task { await box.cancel() } }
        func isCancelled() async -> Bool { await box.isCancelled() }
    }

    public static func getCancellationHandle() -> (handle: CancellationHandle, cancelFunction: () -> Void, isCancelled: () async -> Bool) {
        let box = CancellationBox()
        let handle = CancellationHandle(box: box)
        let cancelFunction: () -> Void = { Task { await box.cancel() } ; return () }
        let isCancelled = { await box.isCancelled() }
        return (handle, cancelFunction, isCancelled)
    }
}
