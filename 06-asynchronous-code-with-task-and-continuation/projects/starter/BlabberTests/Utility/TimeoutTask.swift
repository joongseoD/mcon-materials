//
//  TimeoutTask.swift
//  BlabberTests
//
//  Created by Damor on 2022/02/08.
//

import Foundation

class TimeoutTask<Success> {
  let nanoseconds: UInt64
  let operation: @Sendable () async throws -> Success
  
  private var continuation: CheckedContinuation<Success, Error>?
  
  var value: Success {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        
        Task {
          try await Task.sleep(nanoseconds: nanoseconds)
          self.continuation?.resume(throwing: TimeoutError())
          self.continuation = nil
        }
        
        Task {
          let result = try await operation()
          self.continuation?.resume(returning: result)
          self.continuation = nil
        }
        
        // 두 태스크가 병렬로 실행되고 먼저 완료되면 나중 태스크는 취소된다.
        // 두 태스크가 continuation에 같은 타이밍에 접근하면 크래시가 발생될 수 있다.
        // 이는 actor를 통해 쓰레드 세이프하게 할 수 있다.
      }
    }
  }
  
  init(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Success) {
    self.nanoseconds = UInt64(seconds * 1_000_000_000)
    self.operation = operation
  }
  
  func cancel() {
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}

extension TimeoutTask {
  struct TimeoutError: LocalizedError {
    var errorDescription: String? {
      return "The operation timed out."
    }
  }
}
