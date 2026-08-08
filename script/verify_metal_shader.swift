import Foundation
import Metal

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: verify_metal_shader.swift <ggml-metal.metal>\n".utf8))
    exit(2)
}

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("Metal runtime device is unavailable; trying the offline compiler.\n".utf8))
    exit(77)
}

do {
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let library = try device.makeLibrary(source: source, options: nil)
    guard !library.functionNames.isEmpty else {
        throw NSError(
            domain: "CueMetalVerification",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Metal compiled an empty function library."]
        )
    }
    print("Runtime-compiled packaged Metal shader on \(device.name) (\(library.functionNames.count) functions).")
} catch {
    FileHandle.standardError.write(Data("error: packaged Metal shader did not compile: \(error)\n".utf8))
    exit(1)
}
