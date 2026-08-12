import CoreGraphics
import Foundation
import ImageIO
import Vision

private let protocolVersion = 1

private struct WorkerRequest: Decodable {
    let protocolVersion: Int
    let capability: String
    let input: Input

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case capability, input
    }
}

private struct Input: Decodable {
    let type: String
    let imagePath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case imagePath = "image_path"
    }
}

private struct WorkerResponse: Encodable {
    let protocolVersion: Int
    let output: Output?
    let error: String?
    let retryable: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case output, error, retryable
    }
}

private struct Output: Encodable {
    let type = "ocr"
    let text: String
}

private enum WorkerFailure: LocalizedError {
    case invalidRequest(String)
    case imageLoad(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .imageLoad(let path): "Could not decode OCR image at \(path)"
        }
    }
}

private func recognizeText(at path: String) throws -> String {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw WorkerFailure.imageLoad(path) }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])

    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

private func execute(_ request: WorkerRequest) throws -> Output {
    guard request.protocolVersion == protocolVersion else {
        throw WorkerFailure.invalidRequest("Unsupported worker protocol \(request.protocolVersion)")
    }
    guard request.capability == "ocr", request.input.type == "ocr" else {
        throw WorkerFailure.invalidRequest("The native worker only handles OCR")
    }
    guard let path = request.input.imagePath, !path.isEmpty else {
        throw WorkerFailure.invalidRequest("OCR input is missing image_path")
    }
    return try Output(text: recognizeText(at: path))
}

do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONDecoder().decode(WorkerRequest.self, from: data)
    let response = WorkerResponse(
        protocolVersion: protocolVersion,
        output: try execute(request),
        error: nil,
        retryable: false
    )
    print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
} catch {
    let response = WorkerResponse(
        protocolVersion: protocolVersion,
        output: nil,
        error: error.localizedDescription,
        retryable: false
    )
    let data = try? JSONEncoder().encode(response)
    print(data.map { String(decoding: $0, as: UTF8.self) } ?? "{\"protocol_version\":1,\"error\":\"Native worker failed\",\"retryable\":false}")
}
