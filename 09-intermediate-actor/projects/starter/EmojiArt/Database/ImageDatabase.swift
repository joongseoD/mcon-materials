/// Copyright (c) 2022 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// This project and source code may use libraries or frameworks that are
/// released under various Open-Source licenses. Use of those libraries and
/// frameworks are governed by their own individual licenses.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import UIKit

@globalActor actor ImageDatabase {
  static let shared = ImageDatabase()
  
  let imageLoader = ImageLoader()
  // disk cache 읽기 쓰기 기능 제공하는 class
  // cache를 사용하는 클라이언트는 imageDatabase actor를 통해서 접근한다.
  // 커스텀 init을 통해 storage, sotredImagesIndex를 주입받을 수도 있다
  // ImageDatabase의 프로퍼티인 storage는 class이지만 ImageDatabase global actor에 wrapping 되어있기 때문에 ImageDatabase executor에 의해 serial하게 실행된다.
  private var storage: DiskStorage!
  private var storedImagesIndex = Set<String>()
  
  @MainActor private(set) var onDiskAccessCountStream: AsyncStream<Int>?
  private var onDiskAccessCountStreamContinuation: AsyncStream<Int>.Continuation?
  private var onDiskAccessCount: Int = 0 {
    didSet {
      onDiskAccessCountStreamContinuation?.yield(onDiskAccessCount)
    }
  }
  
  deinit {
    onDiskAccessCountStreamContinuation?.finish()
  }
  
  func setUp() async throws {
    storage = await DiskStorage()
    for fileURL in try await storage.persistedFiles() {
      storedImagesIndex.insert(fileURL.lastPathComponent)
    }
    
    await imageLoader.setUp()
    let accessCounterStream = AsyncStream<Int> { continuation in
      onDiskAccessCountStreamContinuation = continuation
    }
    await MainActor.run {
      onDiskAccessCountStream = accessCounterStream
    }
  }
  
  func store(image: UIImage, forKey key: String) async throws {
    guard let data = image.pngData() else { throw "Could not save image \(key)"}
    let fileName = DiskStorage.fileName(for: key)
    try await storage.write(data, name: fileName)
    storedImagesIndex.insert(fileName)
  }
  
  func image(_ key: String) async throws -> UIImage {
    // memory cache된 이미지가 있으면 return
    if await imageLoader.cache.keys.contains(key) {
      print("Cache in memory")
      return try await imageLoader.image(key)
    }
    
    do {
      // disk cache된 이미지가 있으면 리턴, 없으면 throw error
      let fileName = DiskStorage.fileName(for: key)
      guard storedImagesIndex.contains(fileName) else { throw "Image not persisted" }
      
      let data = try await storage.read(name: fileName)
      guard let image = UIImage(data: data) else { throw "Invalid image data" }
      onDiskAccessCount += 1
      
      print("Cached on disk")
      await imageLoader.add(image, forKey: key)
      return image
    } catch {
      // cache된 이미지가 없는 경우 imageLoader를 통해 server로부터 이미지 다운로드 받는다.
      // 다운로드 된 이미지를 store한 후 return
      let image = try await imageLoader.image(key)
      try await store(image: image, forKey: key)
      return image
    }
  }
  
  func clear() async {
    for name in storedImagesIndex {
      try? await storage.remove(name: name)
    }
    storedImagesIndex.removeAll()
    onDiskAccessCount = 0
  }
  
  func clearInMemoryAssets() async {
    await imageLoader.clear()
  }
}
